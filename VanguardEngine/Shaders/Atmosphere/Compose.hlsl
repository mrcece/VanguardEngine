// Copyright (c) 2019-2022 Andrew Depke

#include "RootSignature.hlsli"
#include "Camera.hlsli"
#include "Geometry.hlsli"
#include "Atmosphere/Atmosphere.hlsli"
#include "Atmosphere/Visibility.hlsli"

struct BindData
{
	AtmosphereData atmosphere;
	uint cameraBuffer;
	uint cameraIndex;
	uint cloudsScatteringTransmittanceTexture;
	uint cloudsDepthTexture;
	uint cloudsVisibilityTexture;
	uint geometryDepthTexture;
	uint outputTexture;
	uint transmissionTexture;
	uint scatteringTexture;
	uint irradianceTexture;
	float solarZenithAngle;
	float globalWeatherCoverage;
};

ConstantBuffer<BindData> bindData : register(b0);

[RootSignature(RS)]
[numthreads(8, 8, 1)]
void Main(uint3 dispatchId : SV_DispatchThreadID)
{
	StructuredBuffer<Camera> cameraBuffer = ResourceDescriptorHeap[bindData.cameraBuffer];
	Texture2D<float4> cloudsScatteringTransmittanceTexture = ResourceDescriptorHeap[bindData.cloudsScatteringTransmittanceTexture];
	Texture2D<float> cloudsDepthTexture = ResourceDescriptorHeap[bindData.cloudsDepthTexture];
	Texture2D<float> cloudsVisibilityTexture = ResourceDescriptorHeap[bindData.cloudsVisibilityTexture];
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
	float2 uv = (dispatchId.xy + 0.5.xx) / float2(width, height);
	
	float geometryDepth = geometryDepthTexture[dispatchId.xy];
	geometryDepth = LinearizeDepth(camera, geometryDepth);
	geometryDepth *= camera.farPlane;
	float cloudsDepth = cloudsDepthTexture.Sample(bilinearClamp, uv) * 1000.f;  // Kilometers to meters.

	float3 sunDirection = float3(sin(bindData.solarZenithAngle), 0.f, cos(bindData.solarZenithAngle));
	float3 rayDirection = ComputeRayDirection(camera, uv);
	float3 cameraPosition = ComputeAtmosphereCameraPosition(camera);
	float3 planetCenter = ComputeAtmospherePlanetCenter(bindData.atmosphere);
	
	bool hitPlanet = false;
	float shadowLength = 0.f;
	
#if defined(RENDER_LIGHT_SHAFTS) && (RENDER_LIGHT_SHAFTS > 0)
	shadowLength = cloudsVisibilityTexture.Sample(bilinearClamp, uv);
	
	// Clouds don't completely block the light, so scale the shadow length accordingly.
	shadowLength *= 0.5f;
	
	// Hack the light shadows to fade in when the sun is at the horizon.
	float lightshaftFadeHack = smoothstep(0.02, 0.04, dot(normalize(cameraPosition - planetCenter), sunDirection));
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
			GetSunAndSkyIrradiance(bindData.atmosphere, transmittanceLut, irradianceLut, bilinearWrap, hitPosition - planetCenter, surfaceNormal, sunDirection, sunIrradiance, skyIrradiance);
		
			float sunVisibility = CalculateSunVisibility(hitPosition, sunCamera /*, ResourceDescriptorHeap[bindData.cloudsShadowMap]*/);
			float skyVisibility = CalculateSkyVisibility(hitPosition, bindData.globalWeatherCoverage);
			
			float3 radiance = bindData.atmosphere.surfaceColor * (1.f / pi) * ((sunIrradiance * sunVisibility) + (skyIrradiance * skyVisibility));
			finalColor = radiance * atmosphereRadianceExposure;
			
			hitPlanet = true;
		}
		
		else
		{
			// Didn't hit the planet, but if the view ray intersects the sun disk, add the direct radiance of the sun on top.
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
				
				finalColor = GetSolarRadiance(bindData.atmosphere) * sunVisibility;
			}	
		}
	}
	
	// After solid geometry has been rendered as a background, compose volumetrics on top.
	if (cloudsDepth < 1000000)
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
		
#ifdef CLOUDS_DEBUG_MARCHCOUNT
		// Debug render should not have aerial perspective applied.
		finalColor = finalColor * cloudsTransmittance + cloudsScattering;
#else	
		// Compute the aerial perspective between the last depth position behind the cloud, and the cloud itself.
		// Note that the shadowLength here is intentionally 0, as we don't care about the shadow behind the cloud, which
		// is probably extremely small if not actually 0 anyways.
		float3 perspectiveTransmittance;
		float3 perspectiveScattering = GetSkyRadianceToPoint(bindData.atmosphere, transmittanceLut, scatteringLut, bilinearWrap, cloudPosition - planetCenter, backPosition - planetCenter, 0.f, sunDirection, perspectiveTransmittance);
		
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
		float3 perspectiveScatteringNear = GetSkyRadianceToPoint(bindData.atmosphere, transmittanceLut, scatteringLut, bilinearWrap, cameraPosition - planetCenter, hitPosition - planetCenter, shadowLength, sunDirection, perspectiveTransmittanceNear);
		float3 perspectiveScatteringFar = GetSkyRadianceToPointNearShadow(bindData.atmosphere, transmittanceLut, scatteringLut, bilinearWrap, cameraPosition - planetCenter, hitPosition - planetCenter, shadowLength, sunDirection, perspectiveTransmittanceFar);
		
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
		perspectiveScattering = GetSkyRadiance(bindData.atmosphere, transmittanceLut, scatteringLut, bilinearWrap, cameraPosition - planetCenter, rayDirection, shadowLength, sunDirection, perspectiveTransmittance);
	}
	
	perspectiveScattering *= atmosphereRadianceExposure;
	finalColor = finalColor * perspectiveTransmittance + perspectiveScattering;

	outputTexture[dispatchId.xy] = float4(finalColor, 1);
}