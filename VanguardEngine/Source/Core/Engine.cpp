// Copyright (c) 2019-2022 Andrew Depke

#include <Core/Engine.h>
#include <Core/Base.h>
#include <Core/Config.h>
#include <Rendering/Device.h>
#include <Rendering/Renderer.h>
#include <Window/WindowFrame.h>
#include <Core/Input.h>
#include <Core/CoreComponents.h>
#include <Core/CoreSystems.h>
#include <Core/CrashHandler.h>
#include <Core/LogSinks.h>

#include <spdlog/spdlog.h>
#include <spdlog/sinks/basic_file_sink.h>
#include <spdlog/sinks/msvc_sink.h>

#include <string>
#include <memory>
#include <chrono>

// #TEMP
#include <Rendering/RenderComponents.h>
#include <Rendering/RenderSystems.h>
#include <Asset/AssetLoader.h>
#include <Utility/Random.h>
#include <Asset/AssetManager.h>
//

entt::registry registry;

void OnFocusChanged(bool focus)
{
	VGScopedCPUStat("Focus Changed");

	VGLog(logWindow, "{}", (focus ? VGText("Acquired focus.") : VGText("Released focus.")));

	// #TODO: Limit render FPS, disable audio.
}

void OnSizeChanged(uint32_t width, uint32_t height)
{
	VGScopedCPUStat("Size Changed");

	VGLog(logWindow, "Render size changed ({}, {}).", width, height);
	Renderer::Get().SetResolution(width, height, false);
}

void EngineBoot()
{
	VGScopedCPUStat("Engine Boot");

	auto fileSink = std::make_shared<spdlog::sinks::basic_file_sink_mt>("Log.txt", true);
	auto msvcSink = std::make_shared<spdlog::sinks::msvc_sink_mt>();
	auto tracySink = std::make_shared<TracySink_mt>();
	auto editorSink = std::make_shared<EditorSink_mt>();
	
	logCore = std::make_shared<spdlog::logger>("core", spdlog::sinks_init_list{ fileSink, msvcSink, tracySink, editorSink });
	logAsset = logCore->clone("asset");
	logEditor = logCore->clone("editor");
	logRendering = logCore->clone("rendering");
	logThreading = logCore->clone("threading");
	logUtility = logCore->clone("utility");
	logWindow = logCore->clone("window");

	spdlog::set_default_logger(logCore);
	spdlog::set_pattern("[%H:%M:%S.%e][tid:%t][%n.%l] %v");
	spdlog::flush_on(spdlog::level::err);
	spdlog::flush_every(1s);

	// Not useful to set an error handler, this isn't invoked unless exceptions are enabled.
	// With exceptions disabled, spdlog just writes to stderr.
	// #TODO: Consider changing the behavior of error handling with exceptions disabled.
	//spdlog::set_error_handler([](const std::string& msg)
	//{
	//	VGLogError(logCore, "Logger: {}", msg);
	//});

	Config::Initialize();

	Input::EnableDPIAwareness();

	constexpr uint32_t defaultWindowSizeX = 1600;
	constexpr uint32_t defaultWindowSizeY = 900;

	auto window = std::make_unique<WindowFrame>(VGText("Vanguard"), defaultWindowSizeX, defaultWindowSizeY);
	window->onFocusChanged = &OnFocusChanged;
	window->onSizeChanged = &OnSizeChanged;

#if BUILD_DEBUG || BUILD_DEVELOPMENT
	constexpr auto enableDebugging = true;
#else
	constexpr auto enableDebugging = false;
#endif

	auto device = std::make_unique<RenderDevice>(static_cast<HWND>(window->GetHandle()), false, enableDebugging);
	Renderer::Get().Initialize(std::move(window), std::move(device), registry);

	// The input requires the user interface to be created first.
	Input::Initialize(Renderer::Get().window->GetHandle());

	// #TEMP
	AssetManager::Get().Initialize(Renderer::Get().device.get());
}

void EngineLoop()
{
	const auto AddHelmet = [](const TransformComponent& transform)
	{
		const auto entity = registry.create();
		registry.emplace<NameComponent>(entity, "Helmet");
		registry.emplace<TransformComponent>(entity, transform);
		registry.emplace<MeshComponent>(entity, AssetManager::Get().LoadModel(Config::shadersPath / "../Assets/Models/DamagedHelmet/HelmetTangents.glb"));

		return entity;
	};

	const auto AddSponza = [](const TransformComponent& transform)
	{
		const auto entity = registry.create();
		registry.emplace<NameComponent>(entity, "Sponza");
		registry.emplace<TransformComponent>(entity, transform);
		registry.emplace<MeshComponent>(entity, AssetManager::Get().LoadModel(Config::shadersPath / "../Assets/Models/Sponza/glTF/Sponza.gltf"));

		return entity;
	};

	const auto AddBistro = [](const TransformComponent& transform)
	{
		const auto entity = registry.create();
		registry.emplace<NameComponent>(entity, "Bistro");
		registry.emplace<TransformComponent>(entity, transform);
		registry.emplace<MeshComponent>(entity, AssetManager::Get().LoadModel(Config::shadersPath / "../Assets/Models/Bistro/Bistro2.gltf"));

		return entity;
	};

	TransformComponent spectatorTransform{};
	spectatorTransform.translation = { 0.f, 0.f, 70.f };
	spectatorTransform.rotation = { 0.f, 0.f, 0.f };

	const auto spectator = registry.create();
	registry.emplace<NameComponent>(spectator, "Spectator");
	registry.emplace<TransformComponent>(spectator, std::move(spectatorTransform));
	registry.emplace<CameraComponent>(spectator);
	registry.emplace<ControlComponent>(spectator);  // #TEMP

	//AddHelmet({
	//	.scale = { 100.f, 100.f, 100.f },
	//	.rotation = { -169.5f * 3.14159f / 180.f, 0.f, 121.5f * 3.14159f / 180.f },
	//	.translation = { 78.f, 0.f, -5.f }
	//});
	const auto h = AssetManager::Get().LoadModel(Config::shadersPath / "../Assets/Models/DamagedHelmet/HelmetTangents.glb");
	for (int i = 0; i < 6; i++)
	{
		float s = i*i * 19.f + 5;
		TransformComponent transform = {
			.scale = { s,s,s },
			.rotation = { -169.5f * 3.14159f / 180.f, 0.f, 121.5f * 3.14159f / 180.f },
			//.rotation = {0.f,0.f,0.f},
			.translation = { i*i*i * 73.f + 40.f * i, i*i * -160.f, 100.f}
		};

		const auto entity = registry.create();
		registry.emplace<TransformComponent>(entity, transform);
		registry.emplace<MeshComponent>(entity, h);
	}
	//
	//AddHelmet({
	//	.scale = { 10.f, 10.f, 10.f },
	//	.rotation = { 169.5f * 3.14159f / 180.f, 0.f, -20.5f * 3.14159f / 180.f },
	//	.translation = { 50.f, -20.f, 8.f }
	//});
	
	//AddSponza({
	//	.scale = { 1.f, 1.f, 1.f },
	//	.rotation = { -90.f * 3.14159f / 180.f, 0.f, 0.f },
	//	//.translation = { 120.f, -3.f, -21.f }
	//	.translation = { 120.f, -3.f, -3500.f }
	//});

	const auto helmetMesh = AssetManager::Get().LoadModel(Config::shadersPath / "../Assets/Models/DamagedHelmet/HelmetTangents.glb");
	int perAxis = 0;
	float spacing = 50.f;
	for (int i = 0; i < perAxis; i++)
	{
		for (int j = 0; j < perAxis; j++)
		{
			for (int k = 0; k < perAxis; k++)
			{
				TransformComponent transform = {
					.scale = { 10.f, 10.f, 10.f },
					.rotation = { (float)Rand(-2.0, 2.0) * 3.142f, (float)Rand(-2.0, 2.0) * 3.142f, (float)Rand(-2.0, 2.0) * 3.142f },
					.translation = {
						(i * spacing) - (perAxis * spacing / 2.f),
						(j * spacing) - (perAxis * spacing / 2.f),
						(k * spacing) - (perAxis * spacing / 2.f)
					}
				};

				const auto entity = registry.create();
				registry.emplace<TransformComponent>(entity, transform);
				registry.emplace<MeshComponent>(entity, helmetMesh);
			}
		}
	}

	const auto light = registry.create();
	registry.emplace<LightComponent>(light, LightComponent{ .type = LightType::Point, .color = { 1.f, 1.f, 1.f } });
	registry.emplace<TransformComponent>(light, TransformComponent{ .scale = { 1.f, 1.f, 1.f }, .rotation = { 0.f, 0.f, 0.f }, .translation = { -15.f, 28.f, 3200.f } });

	int lightCount = 0;//10000;
	//int lightCount = 20000;

	for (int i = 0; i < lightCount; ++i)
	{
		LightComponent pointLight{ .type = LightType::Point, .color = { (float)Rand(0.2f, 1.f), (float)Rand(0.2f, 1.f), (float)Rand(0.2f, 1.f) } };
		// Sponza lights.
		TransformComponent transform{
			.scale = { 1.f, 1.f, 1.f },
			.rotation = { 0.f, 0.f, 0.f },
			.translation = { (float)Rand(-150.0, 150.0), (float)Rand(-65.0, 65.0), (float)Rand(0.0, 120.0) }
		};
		
		// Sun temple lights.
		//TransformComponent transform{
		//	.scale = { 1.f, 1.f, 1.f },
		//	.rotation = { 0.f, 0.f, 0.f },
		//	.translation = { (float)Rand(-150.0, 150.0), (float)Rand(-700, 700), (float)Rand(20, 100) }
		//};

		const auto light = registry.create();
		registry.emplace<LightComponent>(light, pointLight);
		registry.emplace<TransformComponent>(light, transform);
	}

	auto frameBegin = std::chrono::high_resolution_clock::now();
	float lastDeltaTime = 0.f;

	while (true)
	{
		{
			VGScopedCPUStat("Window Message Processing");

			MSG message{};
			if (::PeekMessage(&message, nullptr, 0, 0, PM_REMOVE))
			{
				::TranslateMessage(&message);
				::DispatchMessage(&message);
			}

			if (message.message == WM_QUIT)
			{
				return;
			}
		}

		AssetManager::Get().Update();

		ControlSystem::Update(registry);
		CameraSystem::Update(registry, lastDeltaTime);
		TimeOfDaySystem::Update(registry, lastDeltaTime);

		Renderer::Get().Render(registry);

		Renderer::Get().device->AdvanceCPU();

		auto frameEnd = std::chrono::high_resolution_clock::now();
		const auto frameDelta = std::chrono::duration_cast<std::chrono::microseconds>(frameEnd - frameBegin).count();
		frameBegin = frameEnd;
		lastDeltaTime = static_cast<float>(frameDelta) / 1000000.f;

		Renderer::Get().SubmitFrameTime(frameDelta);
		Input::SubmitFrameTime(frameDelta);
	}
}

void EngineShutdown()
{
	VGScopedCPUStat("Engine Shutdown");

	VGLog(logCore, "Engine shutting down.");
}

int32_t EngineMain()
{
	RegisterCrashHandlers();

	EngineBoot();
	EngineLoop();
	EngineShutdown();

	return 0;
}