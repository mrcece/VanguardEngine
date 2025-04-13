// Copyright (c) 2019-2022 Andrew Depke

#include "RootSignature.hlsli"
#include "Camera.hlsli"
#include "Reprojection.hlsli"

struct BindData
{
	uint cameraBuffer;
	uint cameraIndex;
	uint timeSlice;
	uint geometryDepthTexture;
	uint newScatteringTransmittanceTexture;
	uint newDepthTexture;
	uint newVisibilityTexture;
	uint oldScatteringTransmittanceTexture;
	uint oldDepthTexture;
	uint oldVisibilityTexture;
	uint outputScatteringTransmittanceTexture;
	uint outputDepthTexture;
	uint outputVisibilityTexture;
};

ConstantBuffer<BindData> bindData : register(b0);

// 3x3 neighborhood clamp filter by Playdead Games
// From: https://github.com/playdeadgames/temporal/blob/master/Assets/Shaders/TemporalReprojection.shader
template <typename T, typename U>
T NeighborhoodClampFilter(T source, U targetTexture, uint2 location)
{
	const T a = targetTexture[location + int2(-1, -1)];
	const T b = targetTexture[location + int2(-1, 0)];
	const T c = targetTexture[location + int2(-1, 1)];
	const T d = targetTexture[location + int2(0, -1)];
	const T e = targetTexture[location + int2(0, 0)];
	const T f = targetTexture[location + int2(0, 1)];
	const T g = targetTexture[location + int2(1, -1)];
	const T h = targetTexture[location + int2(1, 0)];
	const T i = targetTexture[location + int2(1, 1)];
	
	// Compute min and max bounds.
	const T minColor = min(min(min(min(min(min(min(min(a, b), c), d), e), f), g), h), i);
	const T maxColor = max(max(max(max(max(max(max(max(a, b), c), d), e), f), g), h), i);
	
	// #TODO: in the future, consider AABB clipping to reduce color grouping.
	return clamp(source, minColor, maxColor);
}

[RootSignature(RS)]
[numthreads(8, 8, 1)]
void Main(uint3 dispatchId : SV_DispatchThreadID)
{
	// Low resolution renders from the current frame.
	Texture2D<float4> newScatTransTexture = ResourceDescriptorHeap[bindData.newScatteringTransmittanceTexture];
	Texture2D<float> newDepthTexture = ResourceDescriptorHeap[bindData.newDepthTexture];
	Texture2D<float> newVisibilityTexture = ResourceDescriptorHeap[bindData.newVisibilityTexture];
	// Upscaled renders from previous frames.
	Texture2D<float4> oldScatTransTexture = ResourceDescriptorHeap[bindData.oldScatteringTransmittanceTexture];
	Texture2D<float> oldDepthTexture = ResourceDescriptorHeap[bindData.oldDepthTexture];
	Texture2D<float> oldVisibilityTexture = ResourceDescriptorHeap[bindData.oldVisibilityTexture];
	// Upscaled outputs for the current frame.
	RWTexture2D<float4> outputScatTransTexture = ResourceDescriptorHeap[bindData.outputScatteringTransmittanceTexture];
	RWTexture2D<float> outputDepthTexture = ResourceDescriptorHeap[bindData.outputDepthTexture];
	RWTexture2D<float> outputVisibilityTexture = ResourceDescriptorHeap[bindData.outputVisibilityTexture];
	
	Texture2D<float> geometryDepthTexture = ResourceDescriptorHeap[bindData.geometryDepthTexture];
	
	uint width, height;
	outputScatTransTexture.GetDimensions(width, height);
	if (dispatchId.x >= width || dispatchId.y >= height)
		return;
	
	if (bindData.oldScatteringTransmittanceTexture == 0 || bindData.oldDepthTexture == 0)
		return;
	
	StructuredBuffer<Camera> cameraBuffer = ResourceDescriptorHeap[bindData.cameraBuffer];
	Camera camera = cameraBuffer[bindData.cameraIndex];
	
	// Divide by 4 with truncation, every pixel must map 1-1 exactly. If the low res texture dimensions are smaller than
	// quarter resolution, then there will be no data in the bottom right. Cannot do an interpolated mapping with UV's
	// as this causes banding to appear.
	uint2 lowResSampleCoords = uint2(dispatchId.xy / 4.xx);
	
	float4 newScatTrans = newScatTransTexture[lowResSampleCoords];
	float newDepth = newDepthTexture[lowResSampleCoords];
	float newVisibility;  // Not doing a simple point sample for this.
	
	// UV coordinates are centered on the middle of the pixel, not the aligned corner.
	float2 newUv = (dispatchId.xy + 0.5.xx) / float2(width, height);
	// #TODO: oldUv is having some issues, maybe precision issues? Crazy motion smears happens on some pixels when not moving.
	float2 oldUv = ReprojectUv(camera, newUv, newDepth);
	
	// Perform a bilinear blur while sampling the visibility texture to denoise a bit.
	newVisibility = newVisibilityTexture.Sample(bilinearClamp, newUv);
	
	// With the reprojected UV coordinates, sample the last frames upscaled data.
	float4 oldScatTrans = oldScatTransTexture.Sample(pointClamp, oldUv);
	float oldDepth = oldDepthTexture.Sample(pointClamp, oldUv);
	
	// Run through a series of history rejection tests to discard bad history.
	bool reject = false;
	
	if (any(oldUv.x > 1.f) || any(oldUv < 0.f))
	{
		reject = true;
	}
	
	// Occlusion detection against geometry.
	float geometryDepth = geometryDepthTexture.Sample(bilinearClamp, newUv);
	geometryDepth = LinearizeDepth(camera, geometryDepth) * camera.farPlane;
	if (geometryDepth < camera.farPlane)
	{
		// Kilometers to meters.
		if (geometryDepth < newDepth * 1000.f)
		{
			reject = true;
		}
	}

	// With the new frame data and the reprojected history, produce a new upscaled render for the current frame.
	
	// Assume only sampling from the current frame render.
	float4 finalScatTrans = newScatTrans;
	float finalDepth = newDepth;
	float finalVisibility = newVisibility;
	
	float blendWeight = JitterAlignedPixel(newUv, uint2(width, height), bindData.timeSlice);
	
	if (!reject)
	{
		// Apply neighborhood clipping.
		// See: https://gdcvault.com/play/1022970/Temporal-Reprojection-Anti-Aliasing-in
		float4 clippedScatTrans = NeighborhoodClampFilter(oldScatTrans, newScatTransTexture, lowResSampleCoords);
		float clippedDepth = NeighborhoodClampFilter(oldDepth, newDepthTexture, lowResSampleCoords);
		
		// Finally, blend together. The clipping work may get entirely discarded if the pixel is not jitter aligned,
		// but oh well.
		finalScatTrans = lerp(newScatTrans, clippedScatTrans, blendWeight);
		finalDepth = lerp(newDepth, clippedDepth, blendWeight);
	}
	
	// Handle visibility upscale last, as we don't have depth information (nor is it very relevant), so perform
	// a simple temporal reproject of it. In addition, the history rejection rules for this are different.
	float2 oldUvDepthless = ReprojectUv(camera, newUv, 10000);
	float oldVisibility = oldVisibilityTexture.Sample(pointClamp, oldUvDepthless);
	finalVisibility = lerp(newVisibility, oldVisibility, blendWeight);
	
	outputScatTransTexture[dispatchId.xy] = finalScatTrans;
	outputDepthTexture[dispatchId.xy] = finalDepth;
	outputVisibilityTexture[dispatchId.xy] = finalVisibility;
}