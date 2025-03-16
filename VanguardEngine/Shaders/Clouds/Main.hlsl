// Copyright (c) 2019-2022 Andrew Depke

#include "RootSignature.hlsli"
#include "Camera.hlsli"
#include "Reprojection.hlsli"
#include "Clouds/Core.hlsli"

struct BindData
{
	uint weatherTexture;
	uint baseShapeNoiseTexture;
	uint detailShapeNoiseTexture;
	uint cameraBuffer;
	uint cameraIndex;
	float solarZenithAngle;
	uint timeSlice;
	uint lastFrameTexture;
	uint2 outputResolution;
	uint depthTexture;
	uint geometryDepthTexture;
	uint blueNoiseTexture;
	uint atmosphereIrradianceBuffer;
	float2 wind;
	float time;
};

ConstantBuffer<BindData> bindData : register(b0);

struct VertexIn
{
	uint vertexId : SV_VertexID;
};

struct PixelIn
{
	float4 positionCS : SV_POSITION;
	float2 uv : UV;
};

[RootSignature(RS)]
PixelIn VSMain(VertexIn input)
{
	PixelIn output;
	output.uv = float2((input.vertexId << 1) & 2, input.vertexId & 2);
	output.positionCS = float4((output.uv.x - 0.5) * 2.0, -(output.uv.y - 0.5) * 2.0, 0, 1);  // Z of 0 due to the inverse depth.

	return output;
}

[RootSignature(RS)]
#ifdef CLOUDS_ONLY_DEPTH
float PSMain(PixelIn input) : SV_Target
#else
float4 PSMain(PixelIn input) : SV_Target
#endif
{
	StructuredBuffer<Camera> cameraBuffer = ResourceDescriptorHeap[bindData.cameraBuffer];
	Camera camera = cameraBuffer[bindData.cameraIndex];

	static const uint crossFilter[] = {
		0, 8, 2, 10,
		12, 4, 14, 6,
		3, 11, 1, 9,
		15, 7, 13, 5
	};

	int2 pixel = input.uv * bindData.outputResolution;
	int index = (pixel.x + 4 * pixel.y) % 16;
#ifdef CLOUDS_FULL_RESOLUTION
	if (true)
#else
	if (index == crossFilter[bindData.timeSlice])
#endif
	{
		float3 sunDirection = float3(sin(bindData.solarZenithAngle), 0.f, cos(bindData.solarZenithAngle));
#ifdef CLOUDS_RENDER_ORTHOGRAPHIC
		// This is equivalent to -sunDirection.
		float3 rayDirection = ComputeRayDirection(camera, 0.5.xx);
#else
		float3 rayDirection = ComputeRayDirection(camera, input.uv);
#endif

		Texture3D<float> baseShapeNoiseTexture = ResourceDescriptorHeap[bindData.baseShapeNoiseTexture];
		Texture3D<float> detailShapeNoiseTexture = ResourceDescriptorHeap[bindData.detailShapeNoiseTexture];
		StructuredBuffer<float3> atmosphereIrradiance = ResourceDescriptorHeap[bindData.atmosphereIrradianceBuffer];
		Texture2D<float3> weatherTexture = ResourceDescriptorHeap[bindData.weatherTexture];
		Texture2D<float> geometryDepthTexture = ResourceDescriptorHeap[bindData.geometryDepthTexture];
		Texture2D<float> blueNoiseTexture = ResourceDescriptorHeap[bindData.blueNoiseTexture];

		float3 scatteredLuminance;
		float transmittance;
		float depth;  // Kilometers.
		RayMarchClouds(baseShapeNoiseTexture, detailShapeNoiseTexture, atmosphereIrradiance, weatherTexture,
			geometryDepthTexture, blueNoiseTexture, camera, input.uv, bindData.outputResolution, rayDirection,
			sunDirection, bindData.wind, bindData.time, scatteredLuminance, transmittance, depth);

#ifdef CLOUDS_ONLY_DEPTH
		return depth;
#else
		RWTexture2D<float> depthTexture = ResourceDescriptorHeap[bindData.depthTexture];
		depthTexture[input.uv * bindData.outputResolution] = depth;

		float4 output;
		output.rgb = scatteredLuminance;
		output.a = transmittance;
		return output;
#endif
	}

#ifndef CLOUDS_FULL_RESOLUTION
	else
	{
		// Not rendering this pixel this frame, so reproject instead.
		Texture2D<float4> lastFrameTexture = ResourceDescriptorHeap[bindData.lastFrameTexture];
		RWTexture2D<float> depthTexture = ResourceDescriptorHeap[bindData.depthTexture];

		// THIS DOESN"T MAKE SENSE! THINK ABOUT THIS MORE
		//
		//
		float depth = depthTexture[input.uv * bindData.outputResolution];
		depth *= 1000.0;  // Convert to meters.

		// Ensure that the reprojected pixel is not now being occluded by geometry.
		Texture2D<float> geometryDepthTexture = ResourceDescriptorHeap[bindData.geometryDepthTexture];

		float geometryDepth = geometryDepthTexture.Sample(bilinearClamp, input.uv);
		geometryDepth = LinearizeDepth(camera, geometryDepth) * camera.farPlane;
		if (geometryDepth < camera.farPlane)
		{
			if (geometryDepth < depth)
			{
				// Geometry masks this pixel.
                return float4(0.xxx, 1);
            }
		}

		float2 reprojectedUv = ReprojectUv(camera, input.uv, depth);

		float4 lastFrame = 0.xxxx;
		if (bindData.lastFrameTexture != 0)
		{
			lastFrame = lastFrameTexture.Sample(downsampleBorder, reprojectedUv);
		}

		return lastFrame;
	}
#endif
}