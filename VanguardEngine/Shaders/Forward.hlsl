// Copyright (c) 2019-2022 Andrew Depke

#include "RootSignature.hlsli"
#include "VertexAssembly.hlsli"
#include "Object.hlsli"
#include "Camera.hlsli"
#include "Material.hlsli"
#include "Light.hlsli"
#include "Clusters/Clusters.hlsli"
#include "IBL/ImageBasedLighting.hlsli"
#include "Atmosphere/Atmosphere.hlsli"
#include "Atmosphere/Visibility.hlsli"

struct ClusterData
{
	uint lightListBuffer;
	uint lightInfoBuffer;
	float logY;
	int froxelSize;
	uint3 dimensions;
	float padding;
};

struct IblData
{
	uint irradianceTexture;
	uint prefilterTexture;
	uint brdfTexture;
	uint prefilterLevels;
};

struct BindData
{
	uint batchId;
	uint objectBuffer;
	uint cameraBuffer;
	uint cameraIndex;
	uint vertexPositionBuffer;
	uint vertexExtraBuffer;
	uint materialBuffer;
	uint lightBuffer;
	uint atmosphereIrradianceBuffer;
	float globalWeatherCoverage;
	uint weatherTexture;
	float padding;
	ClusterData clusterData;
	IblData iblData;
	uint2 outputResolution;
};

ConstantBuffer<BindData> bindData : register(b0);

struct VertexIn
{
	uint vertexId : SV_VertexID;
	uint instanceId : SV_InstanceID;
};

struct PixelIn
{
	float4 positionCS : SV_POSITION;  // Clip space in VS, screen space in PS.
	float3 position : POSITION;  // World space.
	float3 normal : NORMAL;  // World space.
	float2 uv : UV;
	float3 tangent : TANGENT;  // World space.
	float3 bitangent : BITANGENT;  // World space.
	float depthVS : DEPTH;  // View space.
	float4 color : COLOR;
	uint instanceId : SV_InstanceID;
};

[RootSignature(RS)]
PixelIn VSMain(VertexIn input)
{
	StructuredBuffer<ObjectData> objectBuffer = ResourceDescriptorHeap[bindData.objectBuffer];
	ObjectData object = objectBuffer[bindData.batchId + input.instanceId];
	StructuredBuffer<Camera> cameraBuffer = ResourceDescriptorHeap[bindData.cameraBuffer];
	Camera camera = cameraBuffer[bindData.cameraIndex];
	
	VertexAssemblyData assemblyData;
	assemblyData.positionBuffer = bindData.vertexPositionBuffer;
	assemblyData.extraBuffer = bindData.vertexExtraBuffer;
	assemblyData.metadata = object.vertexMetadata;
	
	float4 position = LoadVertexPosition(assemblyData, input.vertexId);
	float4 normal = float4(LoadVertexNormal(assemblyData, input.vertexId), 0.f);
	float2 uv = LoadVertexTexcoord(assemblyData, input.vertexId);
	float4 tangent = LoadVertexTangent(assemblyData, input.vertexId);
	float4 bitangent = LoadVertexBitangent(assemblyData, input.vertexId);
	float4 color = LoadVertexColor(assemblyData, input.vertexId);
	
	PixelIn output;
	output.positionCS = position;
	output.positionCS = mul(output.positionCS, object.worldMatrix);
	output.positionCS = mul(output.positionCS, camera.view);
	output.depthVS = output.positionCS.z;
	output.positionCS = mul(output.positionCS, camera.projection);
	output.position = mul(position, object.worldMatrix).xyz;
	output.normal = normalize(mul(normal, object.worldMatrix)).xyz;
	output.uv = uv;
	output.tangent = normalize(mul(tangent, object.worldMatrix)).xyz;
	output.bitangent = normalize(mul(bitangent, object.worldMatrix)).xyz;
	output.color = color;
	output.instanceId = input.instanceId;
	
	return output;
}

[RootSignature(RS)]
float4 PSMain(PixelIn input) : SV_Target
{
	StructuredBuffer<ObjectData> objectBuffer = ResourceDescriptorHeap[bindData.objectBuffer];
	ObjectData object = objectBuffer[bindData.batchId + input.instanceId];
	StructuredBuffer<Camera> cameraBuffer = ResourceDescriptorHeap[bindData.cameraBuffer];
	Camera camera = cameraBuffer[bindData.cameraIndex];
	Camera sunCamera = cameraBuffer[2];  // #TODO: Remove this terrible hardcoding.
	StructuredBuffer<MaterialData> materialBuffer = ResourceDescriptorHeap[bindData.materialBuffer];
	MaterialData material = materialBuffer[object.materialIndex];
	
	float4 baseColor = input.color;
	
	if (material.baseColor > 0)
	{
		Texture2D<float4> baseColorMap = ResourceDescriptorHeap[material.baseColor];
		baseColor = baseColorMap.Sample(anisotropicWrap, input.uv);
		
		clip(baseColor.a < alphaTestThreshold ? -1 : 1);
	}
	
	float2 metallicRoughness = { 1.0, 1.0 };
	float3 normal = input.normal;
	float ambientOcclusion = 1.0;
	float3 emissive = { 1.0, 1.0, 1.0 };
	
	if (material.metallicRoughness > 0)
	{
		Texture2D<float4> metallicRoughnessMap = ResourceDescriptorHeap[material.metallicRoughness];
		metallicRoughness = metallicRoughnessMap.Sample(anisotropicWrap, input.uv).bg;  // GLTF 2.0 spec.
	}

	if (material.normal > 0)
	{
		// Construct the TBN matrix.
		float3x3 TBN = float3x3(input.tangent, input.bitangent, input.normal);

		Texture2D<float4> normalMap = ResourceDescriptorHeap[material.normal];
		normal = normalMap.Sample(anisotropicWrap, input.uv).rgb;
		normal = normal * 2.0 - 1.0;  // Remap from [0, 1] to [-1, 1].
		normal = normalize(mul(normal, TBN));  // Convert the normal vector from tangent space to world space.
	}

	if (material.occlusion > 0)
	{
		Texture2D<float4> occlusionMap = ResourceDescriptorHeap[material.occlusion];
		ambientOcclusion = occlusionMap.Sample(anisotropicWrap, input.uv).r;
	}

	if (material.emissive > 0)
	{
		Texture2D<float4> emissiveMap = ResourceDescriptorHeap[material.emissive];
		emissive = emissiveMap.Sample(anisotropicWrap, input.uv).rgb;
	}
	
	baseColor *= material.baseColorFactor;
	metallicRoughness *= float2(material.metallicFactor, material.roughnessFactor);
	emissive *= material.emissiveFactor;
	
	float4 output;
	output.rgb = float3(0.0, 0.0, 0.0);
	output.a = baseColor.a;

	float3 viewDirection = normalize(camera.position.xyz - input.position);
	float3 normalDirection = normal;
	
	
	Material materialSample;
	materialSample.baseColor = baseColor;
	materialSample.metalness = metallicRoughness.r;
	materialSample.roughness = metallicRoughness.g * metallicRoughness.g;  // Perceptually linear roughness remapping, from observations by Disney.
	materialSample.normal = normal;
	materialSample.occlusion = ambientOcclusion;
	materialSample.emissive = emissive;
	
	StructuredBuffer<Light> lights = ResourceDescriptorHeap[bindData.lightBuffer];
	StructuredBuffer<uint> clusteredLightList = ResourceDescriptorHeap[bindData.clusterData.lightListBuffer];
	StructuredBuffer<uint2> clusteredLightInfo = ResourceDescriptorHeap[bindData.clusterData.lightInfoBuffer];
	StructuredBuffer<float3> atmosphereIrradiance = ResourceDescriptorHeap[bindData.atmosphereIrradianceBuffer];
	Texture2D<float3> weatherTexture = ResourceDescriptorHeap[bindData.weatherTexture];
	
	uint3 clusterId = DrawToClusterId(bindData.clusterData.froxelSize, bindData.clusterData.logY, camera, input.positionCS.xy, input.depthVS);
	uint2 lightInfo = clusteredLightInfo[ClusterId2Index(bindData.clusterData.dimensions, clusterId)];
	for (uint i = 0; i < lightInfo.y; ++i)
	{
		uint lightIndex = clusteredLightList[lightInfo.x + i];
		Light light = lights[lightIndex];
		
		// Directional lights are just the combined irradiance of the sun and sky.
		if (light.type == LightType::Directional)
		{
			const float3 separatedSunIrradianceNearCamera = atmosphereIrradiance[0];
			const float3 separatedSkyIrradianceNearCamera = atmosphereIrradiance[1];
			
			float3 cameraPositionAtmoSpace = ComputeAtmosphereCameraPosition(camera);
			float3 cameraPoint = cameraPositionAtmoSpace - planetCenter;
			// Convert to kilometers. The atmosphere should probably provide a helper function to convert, but oh well.
			float3 hitPositionAtmoSpace = input.position / 1000.f;
			
			float3 sunIrradiance;
			float3 skyIrradiance;
			RecomposeSeparableSunAndSkyIrradiance(cameraPoint, normal, -light.direction, separatedSunIrradianceNearCamera,
				separatedSkyIrradianceNearCamera, sunIrradiance, skyIrradiance);
			
			const float sunVisibility = CalculateSunVisibility(hitPositionAtmoSpace, light.direction, weatherTexture);
			const float skyVisibility = CalculateSkyVisibility(cameraPositionAtmoSpace, bindData.globalWeatherCoverage);
			
			// Combine both atmospheric irradiance contributions, attenuated by any visibility modifications, such as
			// clouds blocking out the sun.
			// Multiply against the existing color to preserve custom light modifications.
			//light.color *= (sunIrradiance * sunVisibility) + (skyIrradiance * skyVisibility);
			
			// Note that the sky irradiance contribution was removed, since this *should* already be getting contributed
			// by IBL? Comparing IBL lighting with pure skyIrradiance lighting shows that they are nothing alike however,
			// so this is definitely not the most physically accurate model.
			light.color *= (sunIrradiance * sunVisibility);
		}
		
		LightSample sample = SampleLight(light, materialSample, camera, viewDirection, input.position, normalDirection);
		output.rgb += sample.diffuse.rgb;
	}
	
	TextureCube<float4> irradianceMap = ResourceDescriptorHeap[bindData.iblData.irradianceTexture];
	TextureCube<float4> prefilterMap = ResourceDescriptorHeap[bindData.iblData.prefilterTexture];
	Texture2D<float4> brdfMap = ResourceDescriptorHeap[bindData.iblData.brdfTexture];
	
	float width, height, prefilterMipCount;
	prefilterMap.GetDimensions(0, width, height, prefilterMipCount);

	float3 ibl = ComputeIBL(normalDirection, viewDirection, materialSample, bindData.iblData.prefilterLevels, irradianceMap, prefilterMap, brdfMap, anisotropicWrap);
	output.rgb += ibl;

	output.rgb += materialSample.emissive;
	
	return output;
}