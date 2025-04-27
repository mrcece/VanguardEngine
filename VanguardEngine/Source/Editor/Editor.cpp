// Copyright (c) 2019-2022 Andrew Depke

#include <Editor/Editor.h>

#if ENABLE_EDITOR
#include <Editor/EditorUI.h>
#include <Rendering/RenderGraph.h>
#include <Rendering/RenderPass.h>
#include <Rendering/Device.h>
#include <Rendering/Renderer.h>
#include <Rendering/ClusteredLightCulling.h>

#include <imgui.h>
#endif

Editor::Editor()
{
#if ENABLE_EDITOR
	ui = std::make_unique<EditorUI>();
#endif

	// Allow toggling the editor rendering entirely with F1.
	BindKey(ImGuiKey_F1, []()
	{
		auto& editor = Editor::Get();
		editor.enabled = !editor.enabled;
	});

	BindKey(ImGuiKey_R, []()
	{
		Renderer::Get().ReloadShaderPipelines();
	});

	BindKey(ImGuiKey_T, []()
	{
		Renderer::Get().ResetAppTime();
	});
}

Editor::~Editor()
{
	// Destroys the UI.
}

void Editor::Update()
{
	// Creating editor cvars here is simple and doesn't matter if we recreate them every frame.
	CvarCreate("showFps", "Toggles display of FPS on the scene window", +[]()
	{
		Editor::Get().ui->showFps = !Editor::Get().ui->showFps;
	});

	// Process keybinds.
	for (auto& [key, state, bind] : keybinds)
	{
		const auto pressed = ImGui::IsKeyDown(key);
		if (pressed && !state)
		{
			bind();
		}

		state = pressed;
	}

	ui->Update();
}

void Editor::Render(RenderGraph& graph, RenderDevice& device, Renderer& renderer, RenderGraphResourceManager& resourceManager, entt::registry& registry,
	RenderResource cameraBuffer, RenderResource depthStencil, RenderResource outputLDR, RenderResource backBuffer, const ClusterResources& clusterResources,
	RenderResource weather)
{
#if ENABLE_EDITOR
	if (enabled)
	{
		// Render the active overlay if there is one.
		RenderResource activeOverlayTag{};
		switch (ui->activeOverlay)
		{
		case RenderOverlay::None: break;
		case RenderOverlay::Clusters:
		{
			activeOverlayTag = renderer.clusteredCulling.RenderDebugOverlay(graph, clusterResources.lightInfo, clusterResources.lightVisibility);
			break;
		}
		case RenderOverlay::HiZ:
		{
			activeOverlayTag = renderer.occlusionCulling.RenderDebugOverlay(graph, ui->hiZOverlayMip, cameraBuffer);
			break;
		}
		default:
		{
			VGAssert(false, "Render overlay missing tag and view.");
			break;
		}
		}

		auto& editorPass = graph.AddPass("Editor Pass", ExecutionQueue::Graphics);
		editorPass.Read(cameraBuffer, ResourceBind::SRV);
		editorPass.Read(depthStencil, ResourceBind::SRV);
		editorPass.Read(outputLDR, ResourceBind::SRV);
		editorPass.Read(weather, ResourceBind::SRV);
		if (ui->activeOverlay != RenderOverlay::None)
		{
			editorPass.Read(activeOverlayTag, ResourceBind::SRV);
		}
		editorPass.Output(backBuffer, OutputBind::RTV, LoadType::Preserve);
		editorPass.Bind([&, cameraBuffer, depthStencil, outputLDR, weather, activeOverlayTag](CommandList& list, RenderPassResources& resources)
		{
			renderer.userInterface->NewFrame();

			TextureHandle overlayHandle{};
			if (ui->activeOverlay != RenderOverlay::None)
			{
				overlayHandle = resources.GetTexture(activeOverlayTag);
			}

			ui->DrawLayout();
			ui->DrawDemoWindow();
			ui->DrawScene(&device, registry, resources.GetTexture(outputLDR));
			ui->DrawControls(&device);
			ui->DrawEntityHierarchy(registry);
			ui->DrawEntityPropertyViewer(registry);
			ui->DrawMetrics(&device, renderer.lastFrameTime);
			ui->DrawRenderGraph(&device, resourceManager, resources.GetTexture(depthStencil), resources.GetTexture(outputLDR));
			ui->DrawAtmosphereControls(&device, registry, renderer.atmosphere, renderer.clouds, resources.GetTexture(weather));
			ui->DrawBloomControls(renderer.bloom);
			ui->DrawRenderVisualizer(&device, renderer.clusteredCulling, overlayHandle);

			renderer.userInterface->Render(list, resources.GetBuffer(cameraBuffer));
		});
	}

	else
	{
		// Have to update the user interface, otherwise we won't be able to return to the editor later.
		renderer.userInterface->NewFrame();
		ImGui::EndFrame();

		// No editor rendering, just copy outputLDR to the back buffer.
		auto& editorPass = graph.AddPass("Editor Pass", ExecutionQueue::Graphics);
		editorPass.Read(outputLDR, ResourceBind::SRV);
		editorPass.Output(backBuffer, OutputBind::RTV, LoadType::Preserve);
		editorPass.Bind([&, outputLDR](CommandList& list, RenderPassResources& resources)
		{
			list.Copy(resources.GetTexture(backBuffer), resources.GetTexture(outputLDR));
		});
	}
#endif
}

void Editor::BindKey(ImGuiKey key, std::function<void()> function)
{
	keybinds.emplace_back(key, false, std::move(function));
}

void Editor::LogMessage(const std::string& message)
{
	ui->AddConsoleMessage(message);
}