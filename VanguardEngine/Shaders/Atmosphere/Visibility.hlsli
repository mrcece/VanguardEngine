// Copyright (c) 2019-2022 Andrew Depke

#ifndef __VISIBILITY_HLSLI__
#define __VISIBILITY_HLSLI__

#include "Math.hlsli"
#include "Constants.hlsli"
#include "Clouds/Core.hlsli"

// Position must be in atmosphere space.
float CalculateSunVisibility(float3 position, float3 sunDirection, Texture2D<float3> weatherTexture)
{
    // Sample the weather texture as a crude approximation for sun visibility. The ray marched visibility can't be
    // reliably used here as it encodes aggregate shadow along the ray, instead of at the end point.
    float theta = acos(-sunDirection.z);
    float distance = cloudLayerBottom - position.z;
    float displacement = distance * tan(theta) * -sign(sunDirection.x);
    
    float3 weather = SampleWeather(weatherTexture, position + float3(displacement, 0.f, 0.f));
    
    return saturate(1 - min(weather.x, 0.6) * 1.8);
}

// Position must be in atmosphere space.
float CalculateSkyVisibility(float3 position, float globalWeatherCoverage)
{
	// #TODO: Indirect occlusion to the entire sky, use the cloud coverage to approximate this. Only if position is below clouds.
    return 1.f - globalWeatherCoverage;
}

#endif  // __VISIBILITY_HLSLI__