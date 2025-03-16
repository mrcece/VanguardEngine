// Copyright (c) 2019-2022 Andrew Depke

#include "RootSignature.hlsli"
#include "Constants.hlsli"
#include "Camera.hlsli"
#include "Atmosphere/Atmosphere.hlsli"
#include "Clouds/Core.hlsli"

struct BindData
{
	uint outputTexture;
	uint weatherTexture;
	uint baseShapeNoiseTexture;
	uint cameraBuffer;
	uint cameraIndex;
	float solarZenithAngle;
	uint timeSlice;
	uint lastFrameTexture;
	uint geometryDepthTexture;
	uint blueNoiseTexture;
	uint atmosphereIrradianceBuffer;
	float time;
	float2 wind;
};

ConstantBuffer<BindData> bindData : register(b0);

float RayMarch(Camera camera, float2 uv, uint width, uint height)
{	
	float3 sunDirection = float3(sin(bindData.solarZenithAngle), 0.f, cos(bindData.solarZenithAngle));
	float3 rayDirection = ComputeRayDirection(camera, uv);

	Texture3D<float> baseShapeNoiseTexture = ResourceDescriptorHeap[bindData.baseShapeNoiseTexture];
	Texture3D<float> detailShapeNoiseTexture;  // Null texture.
	StructuredBuffer<float3> atmosphereIrradiance = ResourceDescriptorHeap[bindData.atmosphereIrradianceBuffer];
	Texture2D<float3> weatherTexture = ResourceDescriptorHeap[bindData.weatherTexture];
	Texture2D<float> geometryDepthTexture = ResourceDescriptorHeap[bindData.geometryDepthTexture];
	Texture2D<float> blueNoiseTexture = ResourceDescriptorHeap[bindData.blueNoiseTexture];
	
	const float planetRadius = 6360.0;  // #TODO: Get from atmosphere data.
	
	float dist = 0.f;
	float3 origin = ComputeAtmosphereCameraPosition(camera);
	
	float marchStart = 0;
	float marchEnd;
	
	float2 topBoundaryIntersect;
	if (RaySphereIntersection(origin, rayDirection, planetCenter, planetRadius + cloudLayerTop, topBoundaryIntersect))
	{
		marchEnd = topBoundaryIntersect.y;
	}
	else
	{
		// Outside of the cloud layer.
		return 0.f;
	}

	// Stop short if we hit the planet.
	float2 planetIntersect;
	if (RaySphereIntersection(origin, rayDirection, planetCenter, planetRadius, planetIntersect))
	{
		marchEnd = min(marchEnd, planetIntersect.x);
	}

	marchEnd = max(0, marchEnd);
	
	// Early out of the march if we hit opaque geometry.
	float geometryDepth = geometryDepthTexture.Sample(bilinearClamp, uv);
	geometryDepth = LinearizeDepth(camera, geometryDepth) * camera.farPlane;
	if (geometryDepth < camera.farPlane)
	{
		geometryDepth *= 0.001;  // Meters to kilometers.
		marchEnd = min(marchEnd, geometryDepth);
	}
	
	// TODO: early out if we hit a cloud in screenspace too!

	if (marchEnd <= marchStart)
	{
		return 0.f;
	}
	
	uint blueNoiseWidth, blueNoiseHeight;
	blueNoiseTexture.GetDimensions(blueNoiseWidth, blueNoiseHeight);
	float2 blueNoiseSamplePos = uv * uint2(width, height);
	blueNoiseSamplePos = blueNoiseSamplePos / float2(blueNoiseWidth, blueNoiseHeight);
	float rayOffset = blueNoiseTexture.Sample(pointWrap, blueNoiseSamplePos);
	float jitter = (rayOffset - 0.5f) * 2.f;  // Rescale to [-1, 1]
	
	float stepSize = (marchEnd - marchStart) / 20;
	dist += jitter * stepSize;
	
	float totalShadow = 0.f;
	
	while (dist < marchEnd)
	{
		float3 position = origin + rayDirection * dist;
		
		float localMarchStart = 0.f;  // Start at the sample point
		float localMarchEnd = 0.f;
		
		// Local march within the cloud layer boundary.
		float2 topBoundaryIntersect;
		if (RaySphereIntersection(position, sunDirection, planetCenter, planetRadius + cloudLayerTop, topBoundaryIntersect))
		{
			localMarchEnd = topBoundaryIntersect.y;
			
			float2 bottomBoundaryIntersect;
			if (RaySphereIntersection(origin, sunDirection, planetCenter, planetRadius + cloudLayerBottom, bottomBoundaryIntersect))
			{
				float top = all(topBoundaryIntersect > 0) ? min(topBoundaryIntersect.x, topBoundaryIntersect.y) : max(topBoundaryIntersect.x, topBoundaryIntersect.y);
				float bottom = all(bottomBoundaryIntersect > 0) ? min(bottomBoundaryIntersect.x, bottomBoundaryIntersect.y) : max(bottomBoundaryIntersect.x, bottomBoundaryIntersect.y);
				if (all(bottomBoundaryIntersect > 0))
					top = max(0, min(topBoundaryIntersect.x, topBoundaryIntersect.y));
				localMarchStart = min(bottom, top);
				localMarchEnd = max(bottom, top);
			}
		}
		
		
		// March towards the sun.
		float3 scatteredLuminance;
		float transmittance;
		float depth;  // Kilometers.
		RayMarchInternal(baseShapeNoiseTexture, detailShapeNoiseTexture, atmosphereIrradiance, weatherTexture,
			position, sunDirection, 0.f, localMarchStart, localMarchEnd, sunDirection, bindData.wind, bindData.time,
			scatteredLuminance, transmittance, depth);
		
		// Experimenting with weighted contribution to reduce shadows far away.
		float weight = 15.f - 0.12 * pow(dist, 1.5f);
		weight = saturate(weight);
		
		if (transmittance < 1.f)
		{
			totalShadow += stepSize * (1.f - transmittance) * weight;
		}
		
		dist += stepSize;
	}
	
	return totalShadow;
}

[RootSignature(RS)]
[numthreads(8, 8, 1)]
void Main(uint3 dispatchId : SV_DispatchThreadID)
{
	RWTexture2D<float2> outputTexture = ResourceDescriptorHeap[bindData.outputTexture];
	
	uint width, height;
	outputTexture.GetDimensions(width, height);
	
	if (dispatchId.x >= width || dispatchId.y >= height)
		return;
	
	StructuredBuffer<Camera> cameraBuffer = ResourceDescriptorHeap[bindData.cameraBuffer];
	Camera camera = cameraBuffer[bindData.cameraIndex];
	
	float2 uv = (dispatchId.xy + 0.5.xx) / float2(width, height);
	
	static const uint crossFilter[] = {
		0, 8, 2, 10,
		12, 4, 14, 6,
		3, 11, 1, 9,
		15, 7, 13, 5
	};
	
	float shadowLength = 0.f;
	
	int index = (dispatchId.x + 4 * dispatchId.y) % 16;
#ifdef CLOUDS_FULL_RESOLUTION
	if (true)
#else
	if (index == crossFilter[bindData.timeSlice])
#endif
	{
		shadowLength = RayMarch(camera, uv, width, height);
	}
	
#ifndef CLOUDS_FULL_RESOLUTION
	else
	{
		// #TODO: reproject uvs
		
		Texture2D<float> lastFrameTexture = ResourceDescriptorHeap[bindData.lastFrameTexture];
		
		if (bindData.lastFrameTexture != 0)
		{
			float lastFrame = lastFrameTexture.Sample(downsampleBorder, uv);
			shadowLength = lastFrame;
		}
	}
#endif
	
	outputTexture[dispatchId.xy] = float2(shadowLength, 0);
}