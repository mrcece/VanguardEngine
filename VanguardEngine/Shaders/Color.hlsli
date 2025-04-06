// Copyright (c) 2019-2022 Andrew Depke

#ifndef __COLOR_HLSLI__
#define __COLOR_HLSLI__

#include "Math.hlsli"

// Color space conversions credit:
// https://chilliant.blogspot.com/2012/08/srgb-approximations-for-hlsl.html
// Real-time Rendering 4th Edition.

float3 LinearToSRGB(float3 linearColor)
{
	const float3 s1 = sqrt(linearColor);
	const float3 s2 = sqrt(s1);
	const float3 s3 = sqrt(s2);
	return 0.662002687f * s1 + 0.684122060f * s2 - 0.323583601f * s3 - 0.0225411470f * linearColor;
}

float3 SRGBToLinear(float3 sRGBColor)
{
	return sRGBColor * (sRGBColor * (sRGBColor * 0.305306011f + 0.682171111f) + 0.012522878f);
}

// Only for sRGB and Rec. 709 color space.
float LinearToLuminance(float3 linearColor)
{
	return dot(linearColor, float3(0.2126f, 0.7152f, 0.0722f));  // CIE transport function.
}

float3 HsvToRgb(float h, float s, float v)
{
	const float3 rgb = clamp(abs(fmod(h / 60.0 + float3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
	return v * lerp(1.xxx, rgb, s);
}

// Maps a float value in the domain [0, 1] onto a rainbow, starting with green and ending with red.
float3 MapToRainbow(float value)
{
	// Minimum is green, max is red.
    value = RemapRange(value, 0.f, 1.f, 0.33f, 1.f);
	
    float hue = 360.0 * saturate(value);
    return HsvToRgb(hue, 1.0, 1.0);
}

#endif  // __COLOR_HLSLI__