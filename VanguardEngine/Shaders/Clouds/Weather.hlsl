// Copyright (c) 2019-2022 Andrew Depke

#include "RootSignature.hlsli"
#include "Noise.hlsli"
#include "Math.hlsli"

struct BindData
{
	uint weatherTexture;
	float globalCoverage;
	float precipitation;
	float time;
	float2 wind;
};

ConstantBuffer<BindData> bindData : register(b0);

[RootSignature(RS)]
[numthreads(8, 8, 1)]
void Main(uint3 dispatchId : SV_DispatchThreadID)
{
	// Weather is composed of coverage, type, and precipitation.
	RWTexture2D<float3> weatherTexture = ResourceDescriptorHeap[bindData.weatherTexture];

	uint width, height;
	weatherTexture.GetDimensions(width, height);
	float weatherSize = float(width);

	float2 coord = float2(dispatchId.xy) * (1.0 / weatherSize);

	const float timeDilation = 0.003;
	coord += bindData.wind * bindData.time * timeDilation;

	float coverage = PerlinNoise2D(coord, 8, 4);
	coverage = saturate(RemapRange(coverage, 1.0 - bindData.globalCoverage, 1, 0, 1));
	
	float type = PerlinNoise2D(coord * 2.5, 4, 4);
	type = RemapRange(type, 0.29, 0.8, 0.f, 0.95f);
	// Coverage should influence the cloud types. Lower coverage should increase probability of
	// smaller clouds, while high coverage should promote larger masses.
	type += bindData.globalCoverage * 0.6 - 0.3;
	type = saturate(type);
	
	float precipitation = pow(1 + bindData.precipitation, 1.5);  // #TODO: variation.

	weatherTexture[dispatchId.xy] = float3(coverage, type, precipitation);
}