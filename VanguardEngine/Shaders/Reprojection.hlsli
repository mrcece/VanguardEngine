// Copyright (c) 2019-2022 Andrew Depke

#ifndef __REPROJECTION_HLSLI__
#define __REPROJECTION_HLSLI__

#include "Camera.hlsli"

static const uint crossFilter[] = {
	0, 8, 2, 10,
	12, 4, 14, 6,
	3, 11, 1, 9,
	15, 7, 13, 5
};

static const uint2 crossFilterOffsets[] = {
	uint2(0, 0), uint2(2, 2), uint2(0, 2), uint2(2, 0),
	uint2(1, 1), uint2(3, 3), uint2(1, 3), uint2(3, 1),
	uint2(0, 1), uint2(2, 3), uint2(0, 3), uint2(2, 1),
	uint2(1, 0), uint2(3, 2), uint2(1, 2), uint2(3, 0)
};

// Applies a jitter offset to the given UV coordinates in upscaled resolution space. Note that the jitter is exclusively positive,
// and will not return UV coordinates < inputUv.
float2 JitterUv(float2 inputUv, uint2 resolution, int time)
{
	const uint2 offset = crossFilterOffsets[time % 16];
	const float2 offsetScreenSpace = float2(offset) / float2(resolution);

	return inputUv + offsetScreenSpace;
}

// Branchless method of essentially just checking if the current pixel index is the active pixel in the cross filter.
float JitterAlignedPixel(float2 inputUv, uint2 resolution, int time)
{
	const uint2 offset = crossFilterOffsets[time % 16];
	const float2 localPixel = floor(fmod(inputUv * resolution, 4.f));
	const float2 localOffset = abs(localPixel - offset);
	
	// This will return 1 for all pixels that don't match the current pixel in the cross filter, 0 for that one pixel.
	return saturate(localOffset.x + localOffset.y);
}

float2 ReprojectUv(Camera camera, float2 inputUv, float depth)
{
	matrix viewProjection = mul(camera.view, camera.projection);
	matrix inverseViewProjection = mul(camera.lastFrameInverseProjection, camera.lastFrameInverseView);
	
	// Convert to world space of the previous frame.
	float4 clipSpace = UvToClipSpace(inputUv);
	float4 worldSpace = mul(clipSpace, inverseViewProjection);
	worldSpace /= worldSpace.w;

	// Scale by the depth.
	float3 ray = normalize(worldSpace.xyz - camera.lastFramePosition.xyz);
	worldSpace = float4(camera.position.xyz + ray * depth, 1.f);
	
	// Convert back to clip space of the current frame.
	float4 reprojected = mul(worldSpace, viewProjection);
	reprojected /= reprojected.w;

	float2 delta = inputUv - ClipSpaceToUv(reprojected);
	return inputUv + delta;
}

#endif  // __REPROJECTION_HLSLI__