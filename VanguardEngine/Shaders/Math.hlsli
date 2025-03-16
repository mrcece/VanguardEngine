// Copyright (c) 2019-2022 Andrew Depke

#ifndef __MATH_HLSLI__
#define __MATH_HLSLI__

float RemapRange(float value, float inMin, float inMax, float outMin, float outMax)
{
    return outMin + (((value - inMin) / (inMax - inMin)) * (outMax - outMin));
}

#endif  // __MATH_HLSLI__