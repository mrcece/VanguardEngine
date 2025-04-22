// Copyright (c) 2019-2022 Andrew Depke

#include "RootSignature.hlsli"
#include "Camera.hlsli"
#include "Geometry.hlsli"
#include "Atmosphere/Atmosphere.hlsli"
#include "Atmosphere/Visibility.hlsli"

struct BindData
{
	uint cameraBuffer;
	uint cameraIndex;
	uint atmosphereBuffer;
	uint cloudsScatteringTransmittanceTexture;
	uint cloudsDepthTexture;
	uint cloudsVisibilityTexture;
	uint cloudsCirrusTexture;
	uint geometryDepthTexture;
	uint outputTexture;
	uint transmissionTexture;
	uint scatteringTexture;
	uint irradianceTexture;
	float solarZenithAngle;
	float globalWeatherCoverage;
	float2 wind;
	float time;
};

ConstantBuffer<BindData> bindData : register(b0);

float3 SampleCirrusClouds(Texture2D<float4> cirrusTexture, float3 planetCenter, float3 cameraPosition, float3 rayDirection, out float3 hitPosition)
{
	// Cirrus clouds are in the range of 15k-30k feet. So pick a nice value in the middle.
	const float cirrusHeight = 6705.f / 1000.f;
	
	hitPosition = 0.xxx;
	
	const float planetRadius = 6360.0;
	float2 topBoundaryIntersect;
	if (!RaySphereIntersection(cameraPosition, rayDirection, planetCenter, planetRadius + cirrusHeight, topBoundaryIntersect))
	{
		// Outside the cirrus layer.
		return 0.xxx;
	}
	
	float distanceToLayer = topBoundaryIntersect.y;
	hitPosition = rayDirection * distanceToLayer + cameraPosition;
	
	// Convert the hit position to global space instead of in atmosphere-local space, otherwise the spherical
	// coordinates will not be correct. Note that the returned hit position is local space, so that the distance through
	// the atmosphere is correct.
	float3 hitGlobalSpace = hitPosition + planetCenter;
	
	// Convert the cartesian direction to normalized spherical coordinates.
	// Note that the X axis is used as the polar axis, instead of Z to focus spherical distortion towards the horizon,
	// instead of straight up.
	const float radius = length(hitGlobalSpace);
	const float theta = atan(hitGlobalSpace.y / hitGlobalSpace.z);
	const float phi = acos(hitGlobalSpace.x / radius);
	
	const float uvScale = 120.f;
	float2 uv = float2(-phi * uvScale, -theta * uvScale);
	
	// Apply wind by scrolling the UV coordinates. Wind tends to move faster as you get higher in the atmosphere,
	// so scale faster than the rest of the clouds.
	uv += bindData.wind * bindData.time * 0.038;
	
	float opacityScale = smoothstep(0.f, 0.4f, bindData.globalWeatherCoverage);
	
	return cirrusTexture.Sample(bilinearWrap, uv).aaa * opacityScale;
}

[RootSignature(RS)]
[numthreads(8, 8, 1)]
void Main(uint3 dispatchId : SV_DispatchThreadID)
{
	StructuredBuffer<Camera> cameraBuffer = ResourceDescriptorHeap[bindData.cameraBuffer];
	StructuredBuffer<AtmosphereData> atmosphereBuffer = ResourceDescriptorHeap[bindData.atmosphereBuffer];
	Texture2D<float4> cloudsScatteringTransmittanceTexture = ResourceDescriptorHeap[bindData.cloudsScatteringTransmittanceTexture];
	Texture2D<float> cloudsDepthTexture = ResourceDescriptorHeap[bindData.cloudsDepthTexture];
	Texture2D<float> cloudsVisibilityTexture = ResourceDescriptorHeap[bindData.cloudsVisibilityTexture];
	Texture2D<float4> cloudsCirrusTexture = ResourceDescriptorHeap[bindData.cloudsCirrusTexture];
	Texture2D<float> geometryDepthTexture = ResourceDescriptorHeap[bindData.geometryDepthTexture];
	RWTexture2D<float4> outputTexture = ResourceDescriptorHeap[bindData.outputTexture];

	Texture2D<float4> transmittanceLut = ResourceDescriptorHeap[bindData.transmissionTexture];
	Texture3D<float4> scatteringLut = ResourceDescriptorHeap[bindData.scatteringTexture];
	Texture2D<float4> irradianceLut = ResourceDescriptorHeap[bindData.irradianceTexture];

	uint width, height;
	outputTexture.GetDimensions(width, height);
	if (dispatchId.x >= width || dispatchId.y >= height)
		return;

	Camera camera = cameraBuffer[bindData.cameraIndex];
	Camera sunCamera = cameraBuffer[2];  // #TODO: Remove this terrible hardcoding.
	
	AtmosphereData atmosphere = atmosphereBuffer[0];
	
	float2 uv = (dispatchId.xy + 0.5.xx) / float2(width, height);
	
	float geometryDepth = geometryDepthTexture[dispatchId.xy];
	geometryDepth = LinearizeDepth(camera, geometryDepth);
	geometryDepth *= camera.farPlane;
	float cloudsDepth = cloudsDepthTexture.Sample(bilinearClamp, uv) * 1000.f;  // Kilometers to meters.

	float3 sunDirection = float3(sin(bindData.solarZenithAngle), 0.f, cos(bindData.solarZenithAngle));
	float3 rayDirection = ComputeRayDirection(camera, uv);
	float3 cameraPosition = ComputeAtmosphereCameraPosition(camera);
	float3 planetCenter = ComputeAtmospherePlanetCenter(atmosphere);
	
	bool hitPlanet = false;
	float shadowLength = 0.f;
	
#if defined(RENDER_LIGHT_SHAFTS) && (RENDER_LIGHT_SHAFTS > 0)
	shadowLength = cloudsVisibilityTexture.Sample(bilinearClamp, uv);
	
	// Soften the shadows a bit, except when looking at the sun. Shadows cast by clouds when looking at the sun
	// should be more dramatic to make the effect obvious.
	const float muS = dot(rayDirection, sunDirection);
	shadowLength *= 0.5 * smoothstep(0.85, 1.0, muS) + 0.5;
	
	// Hack the light shadows to fade in when the sun is at the horizon.
	float lightshaftFadeHack = smoothstep(0.01, 0.04, dot(normalize(cameraPosition - planetCenter), sunDirection));
	shadowLength = max(0.f, shadowLength * lightshaftFadeHack);
#endif
	
	// The following sequence is a correct composition of volumetrics and geometry. It is not optimized at all
	// however, so some of the work can likely be cut out.
	
	float3 finalColor = 0.xxx;
	float lastDepth = -1;  // The depth needs to be tracked to compose volumetrics.
	
	bool hitSurface = geometryDepth < camera.farPlane;
	if (hitSurface)
	{
		// Hit solid geometry, the direct lighting is already done in the forward pass.
		
		float depth = geometryDepth * 0.001;  // Meters to kilometers.
		lastDepth = depth;
		
		float3 inputColor = outputTexture[dispatchId.xy].xyz;
		finalColor = inputColor;
	}
	
	else
	{
		// Didn't hit any geometry, but could've hit the planet surface.
		
		float3 p = cameraPosition - planetCenter;
		float pDotRay = dot(p, rayDirection);
		float intersectionDistance = -pDotRay - sqrt(planetCenter.z * planetCenter.z - (dot(p, p) - (pDotRay * pDotRay)));
	
		if (intersectionDistance > 0.f)
		{
			// Hit the planet, compute the sun and sky light reflecting off, with the aerial perspective to that point.
			
			float3 hitPosition = cameraPosition + rayDirection * intersectionDistance;
			lastDepth = intersectionDistance;
			float3 surfaceNormal = normalize(hitPosition - planetCenter);
			
			float3 sunIrradiance;
			float3 skyIrradiance;
			GetSunAndSkyIrradiance(atmosphere, transmittanceLut, irradianceLut, bilinearWrap, hitPosition - planetCenter, surfaceNormal, sunDirection, sunIrradiance, skyIrradiance);
		
			// The irradiance on the planet surface is heavily influenced by visibility.
			float sunVisibility = CalculateSunVisibility(hitPosition, sunCamera /*, ResourceDescriptorHeap[bindData.cloudsShadowMap]*/);
			float skyVisibility = CalculateSkyVisibility(hitPosition, bindData.globalWeatherCoverage);
			
			float3 radiance = atmosphere.surfaceColor * (1.f / pi) * ((sunIrradiance * sunVisibility) + (skyIrradiance * skyVisibility));
			finalColor = radiance * atmosphereRadianceExposure;
			
			hitPlanet = true;
		}
		
		else
		{
			// Didn't hit the planet, use the cirrus cloud layer as the background.
			float3 hitPosition;
			finalColor = SampleCirrusClouds(cloudsCirrusTexture, planetCenter, cameraPosition, rayDirection, hitPosition);
			lastDepth = length(hitPosition) - 0.00001;  // Subtract a small number so that no hit corresponds with a negative depth.
			
			// Using the sun direction as the normal vector causes artifacts when the sun is setting.
			float3 surfaceNormal = float3(0, 0, 1);
			
			float3 sunIrradiance;
			float3 skyIrradiance;
			GetSunAndSkyIrradiance(atmosphere, transmittanceLut, irradianceLut, bilinearWrap, hitPosition - planetCenter, surfaceNormal, sunDirection, sunIrradiance, skyIrradiance);
			
			// The irradiance on the cirrus clouds is not impacted by visibility, so skip that computation.
			finalColor *= (sunIrradiance + skyIrradiance);
			
			// If the view ray intersects the sun disk, add the direct radiance of the sun on top.
			if (dot(rayDirection, sunDirection) > cos(sunAngularRadius))
			{
				float sunVisibility = 1.f;
				
				// Instead of using CalculateSunVisibility as an approximation for the sun visibility, we can be much more accurate
				// here by just sampling the cloud transmittance map directly. We can do this here since this is a screen space rendering
				// of the sun disk.
				if (cloudsDepth < 1000000)
				{
					float4 cloudsCombined = cloudsScatteringTransmittanceTexture.Sample(bilinearClamp, uv);  // scat=0, trans=1 when no data available
					
					// Hack since for some reason fully occluding clouds are not 0% transmittance. This ensures that when
					// the sun is hidden behind thick clouds, absolutely no direct sun is visible.
					sunVisibility = max(cloudsCombined.w - 0.01f, 0.f);
				}
				
				finalColor = GetSolarRadiance(atmosphere) * sunVisibility;
			}
		}
	}

	// After solid geometry has been rendered as a background, compose volumetrics on top.
	if (cloudsDepth < 1000000 && (!hitSurface || geometryDepth > cloudsDepth))
	{
		// Hit a cloud, need to apply the in-scattered light of the media over material behind it.
	
		float4 cloudsCombined = cloudsScatteringTransmittanceTexture.Sample(bilinearClamp, uv);  // scat=0, trans=1 when no data available
		float3 cloudsScattering = cloudsCombined.xyz;
		float3 cloudsTransmittance = cloudsCombined.www;
		
		// Don't let the depth be 0, as this will cause a NaN in the aerial perspective equation.
		float depth = max(cloudsDepth, 0.01) * 0.001;  // Meters to kilometers.
		float3 backPosition = cameraPosition + rayDirection * lastDepth;
		float3 cloudPosition = cameraPosition + rayDirection * depth;
		lastDepth = depth;
		
		// Debug rendering should not have aerial perspective applied.
#if defined(CLOUDS_DEBUG_MARCHCOUNT)
		finalColor = finalColor * cloudsTransmittance + cloudsScattering;
#elif defined(CLOUDS_DEBUG_TRANSMITTANCE)
		finalColor = cloudsTransmittance;
#else	
		// Compute the aerial perspective between the last depth position behind the cloud, and the cloud itself.
		// Note that the shadowLength here is intentionally 0, as we don't care about the shadow behind the cloud, which
		// is probably extremely small if not actually 0 anyways.
		float3 perspectiveTransmittance;
		float3 perspectiveScattering = GetSkyRadianceToPoint(atmosphere, transmittanceLut, scatteringLut, bilinearWrap, cloudPosition - planetCenter, backPosition - planetCenter, 0.f, sunDirection, perspectiveTransmittance);
		
		// Composite.
		perspectiveScattering *= atmosphereRadianceExposure;
		
		finalColor = finalColor * perspectiveTransmittance + perspectiveScattering;
		finalColor = finalColor * cloudsTransmittance + cloudsScattering;
#endif
	}
	
	// Done composing intermediary volumetrics, now apply final aerial perspective on top.
	
	float3 perspectiveScattering;
	float3 perspectiveTransmittance;
	
	if (lastDepth >= 0.f)
	{
		float3 hitPosition = cameraPosition + rayDirection * lastDepth;
		
		// This is a horrible hack, possibly one of the worst in the whole project.
		// GetSkyRadianceToPoint treats shadows as omission of scattering near the camera, while
		// GetSkyRadiance treats shadows as omission away from the camera, at the other end of the view ray.
		// This disparity causes far away clouds, which are viewed by a ray that is traversing some volume
		// of shadow, to appear too bright against a darkened sky, as all that in-scattered light from the sky
		// is not occluded at the eye, while the surrouding sky does account for that.
		// As a result, GetSkyRadianceToPointNearShadow was created, which is not at all correct but a good
		// enough approximation for distant objects. Ideally, there would be no blending done here and the
		// GetSkyRadianceToPointNearShadow function would be used, but I don't have the time to properly
		// fix that function to be correct.
		
		float3 perspectiveTransmittanceNear;
		float3 perspectiveTransmittanceFar;
		float3 perspectiveScatteringNear = GetSkyRadianceToPoint(atmosphere, transmittanceLut, scatteringLut, bilinearWrap, cameraPosition - planetCenter, hitPosition - planetCenter, shadowLength, sunDirection, perspectiveTransmittanceNear);
		float3 perspectiveScatteringFar = GetSkyRadianceToPointNearShadow(atmosphere, transmittanceLut, scatteringLut, bilinearWrap, cameraPosition - planetCenter, hitPosition - planetCenter, shadowLength, sunDirection, perspectiveTransmittanceFar);
		
		// Blend between the near and far values.
#ifdef ENABLE_FAR_SHADOW_FIX
		float blendFactor = smoothstep(20, 90, lastDepth);
		
		if (hitPlanet)
		{
			blendFactor = 1.f;
		}
#else
		float blendFactor = 0.f;
#endif
		
		perspectiveScattering = lerp(perspectiveScatteringNear, perspectiveScatteringFar, blendFactor);
		perspectiveTransmittance = lerp(perspectiveTransmittanceNear, perspectiveTransmittanceFar, blendFactor);
	}
	
	else
	{
		perspectiveScattering = GetSkyRadiance(atmosphere, transmittanceLut, scatteringLut, bilinearWrap, cameraPosition - planetCenter, rayDirection, shadowLength, sunDirection, perspectiveTransmittance);
	}
	
	perspectiveScattering *= atmosphereRadianceExposure;
	finalColor = finalColor * perspectiveTransmittance + perspectiveScattering;
	
	outputTexture[dispatchId.xy] = float4(finalColor, 1);
}