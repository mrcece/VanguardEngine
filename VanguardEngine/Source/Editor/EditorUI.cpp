// Copyright (c) 2019-2022 Andrew Depke

#include <Editor/EditorUI.h>
#include <Rendering/Device.h>
#include <Rendering/Renderer.h>
#include <Rendering/RenderGraphResourceManager.h>
#include <Core/CoreComponents.h>
#include <Rendering/RenderComponents.h>
#include <Editor/EntityReflection.h>
#include <Editor/ImGuiExtensions.h>
#include <Editor/CvarHelpers.h>
#include <Rendering/Atmosphere.h>
#include <Rendering/Clouds.h>
#include <Rendering/Bloom.h>
#include <Rendering/ClusteredLightCulling.h>
#include <Utility/Math.h>

#include <imgui_internal.h>

#include <algorithm>
#include <numeric>
#include <string>
#include <sstream>
#include <optional>

void EditorUI::DrawMenu()
{
	if (ImGui::BeginMenuBar())
	{
		if (ImGui::BeginMenu("View"))
		{
			ImGui::MenuItem("Controls", nullptr, &controlsOpen);
			ImGui::MenuItem("Console", "F2", &consoleOpen);
			ImGui::MenuItem("Entity Hierarchy", nullptr, &entityHierarchyOpen);
			ImGui::MenuItem("Entity Properties", nullptr, &entityPropertyViewerOpen);
			ImGui::MenuItem("Metrics", nullptr, &metricsOpen);
			ImGui::MenuItem("Render Graph", nullptr, &renderGraphOpen);
			ImGui::MenuItem("Atmosphere Controls", nullptr, &atmosphereControlsOpen);
			ImGui::MenuItem("Bloom Controls", nullptr, &bloomControlsOpen);
			ImGui::MenuItem("Render Visualizer", nullptr, &renderVisualizerOpen);

			ImGui::EndMenu();
		}

		if (ImGui::BeginMenu("Window"))
		{
			ImGui::MenuItem("Fullscreen", nullptr, &fullscreen);

			ImGui::EndMenu();
		}

		ImGui::EndMenuBar();
	}
}

void EditorUI::DrawFrameTimeHistory()
{
	// Compute statistics.
	const auto [min, max] = std::minmax_element(frameTimes.begin(), frameTimes.end());
	const auto mean = std::accumulate(frameTimes.begin(), frameTimes.end(), 0) / static_cast<float>(frameTimes.size());

	auto* window = ImGui::GetCurrentWindow();
	auto& style = ImGui::GetStyle();

	const auto frameWidth = ImGui::GetContentRegionAvail().x - window->WindowPadding.x - ImGui::CalcTextSize("Mean: 00.000").x;
	const auto frameHeight = (ImGui::GetTextLineHeight() + style.ItemSpacing.y) * 3.f + 10.f;  // Max, mean, min.

	const ImRect frameBoundingBox = { window->DC.CursorPos, window->DC.CursorPos + ImVec2{ frameWidth, frameHeight } };

	ImGui::ItemSize(frameBoundingBox, style.FramePadding.y);
	if (!ImGui::ItemAdd(frameBoundingBox, 0))  // Don't support navigation to the frame.
	{
		return;
	}

	ImGui::RenderFrame(frameBoundingBox.Min, frameBoundingBox.Max, ImGui::GetColorU32(ImGuiCol_FrameBg), true, style.FrameRounding);

	// Internal region for rendering the plot lines.
	const ImRect frameRenderSpace = { frameBoundingBox.Min + style.FramePadding, frameBoundingBox.Max - style.FramePadding };

	// Adaptively update the sample count.
	frameTimeHistoryCount = frameRenderSpace.GetWidth() / 2.f;

	if (frameTimes.size() > 1)
	{
		// Pad out the min/max range.
		const auto range = std::max((*max - *min) + 5.f, 20.f);

		const ImVec2 lineSize = { frameRenderSpace.GetWidth() / (frameTimes.size() - 1), frameRenderSpace.GetHeight() / (range * 2.f) };
		const auto lineColor = ImGui::ColorConvertFloat4ToU32(style.Colors[ImGuiCol_PlotLines]);

		for (int i = 0; i < frameTimes.size() - 1; ++i)  // Don't draw the final point.
		{
			window->DrawList->AddLine(
				{ frameRenderSpace.Min.x + (lineSize.x * i), frameRenderSpace.Min.y + (frameRenderSpace.GetHeight() / 2.f) + (mean - frameTimes[i]) * lineSize.y },
				{ frameRenderSpace.Min.x + (lineSize.x * (i + 1)), frameRenderSpace.Min.y + (frameRenderSpace.GetHeight() / 2.f) + (mean - frameTimes[i + 1]) * lineSize.y },
				lineColor);
		}
	}

	if (min != frameTimes.end() && max != frameTimes.end())
	{
		ImGui::SameLine();
		ImGui::BeginGroup();

		ImGui::Text("Max:  %.3f", *max / 1000.f);
		ImGui::Text("Mean: %.3f", mean / 1000.f);
		ImGui::Text("Min:  %.3f", *min / 1000.f);

		ImGui::EndGroup();
	}
}

void EditorUI::DrawRenderOverlayTools(RenderDevice* device, const ImVec2& min, const ImVec2& max)
{
	const auto toolsWindowFlags =
		ImGuiWindowFlags_NoDecoration |
		ImGuiWindowFlags_NoScrollWithMouse |
		//ImGuiWindowFlags_NoBackground |
		ImGuiWindowFlags_NoSavedSettings |
		ImGuiWindowFlags_NoFocusOnAppearing |
		ImGuiWindowFlags_NoNav |
		//ImGuiWindowFlags_NoInputs |
		ImGuiWindowFlags_NoDocking;

	enum class ToolPosition
	{
		Bottom,
		Right
	};

	ImVec2 toolWindowSize = { 100, 100 };
	ToolPosition position = ToolPosition::Bottom;

	switch (activeOverlay)
	{
	case RenderOverlay::Clusters:
		toolWindowSize = { 480, 50 };
		position = ToolPosition::Bottom;
		break;
	case RenderOverlay::HiZ:
		toolWindowSize = { 70, 300 };
		position = ToolPosition::Right;
		break;
	}

	const auto padding = 15.f;
	const auto windowBase = ImGui::GetWindowPos();  // Not sure why we need this, oh well.

	switch (position)
	{
	case ToolPosition::Bottom:
		ImGui::SetNextWindowPos({ windowBase.x + (max.x - min.x - toolWindowSize.x) * 0.5f, max.y - toolWindowSize.y - padding });
		break;
	case ToolPosition::Right:
		ImGui::SetNextWindowPos({ max.x - toolWindowSize.x - padding, windowBase.y + (max.y - min.y - toolWindowSize.y) * 0.5f });
		break;
	}

	if (ImGui::BeginChildFrame(ImGui::GetID("Render Overlay Tools"), toolWindowSize, toolsWindowFlags))
	{
		auto style = ImGui::GetStyle();

		switch (activeOverlay)
		{
		case RenderOverlay::Clusters:
		{
			// Color scale.

			const char* titleText = "Cluster froxel bins light count";
			const char* leftText = "0";
			char rightText[8];
			ImFormatString(rightText, std::size(rightText), "%i", *CvarGet("maxLightsPerFroxel", int));

			const auto titleSize = ImGui::CalcTextSize(titleText);
			const auto leftSize = ImGui::CalcTextSize(leftText);
			const auto rightSize = ImGui::CalcTextSize(rightText);

			ImGui::SetCursorPosX((toolWindowSize.x - titleSize.x) * 0.5f);
			ImGui::Text(titleText);

			const auto sceneViewportSize = max - min;
			const auto colorScaleSize = ImVec2{ toolWindowSize.x - std::max(leftSize.x, rightSize.x) * 2.f - style.FramePadding.x * 2.f - 4.f, 20.f };
			auto colorScalePosMin = ImGui::GetWindowPos();
			colorScalePosMin += { (toolWindowSize.x - colorScaleSize.x) * 0.5f, ImGui::GetCursorPosY() };
			auto* drawList = ImGui::GetWindowDrawList();
			drawList->AddRectFilledMultiColor(colorScalePosMin, colorScalePosMin + colorScaleSize, IM_COL32(0, 255, 0, 255), IM_COL32(255, 0, 0, 255), IM_COL32(255, 0, 0, 255), IM_COL32(0, 255, 0, 255));

			ImGui::SetCursorPosY(ImGui::GetCursorPosY() + 2.f);
			ImGui::Text(leftText);

			ImGui::SameLine();
			ImGui::SetCursorPosX(toolWindowSize.x - rightSize.x - style.FramePadding.x);
			ImGui::Text(rightText);

			break;
		}

		case RenderOverlay::HiZ:
		{
			// Mip selector.

			const auto sceneViewportSize = sceneViewportMax - sceneViewportMin;
			char viewText[32];
			ImFormatString(viewText, std::size(viewText), "Depth\nPyramid\nLevel");
			const auto viewTextSize = ImGui::CalcTextSize(viewText);

			ImGui::Text(viewText);

			const auto& overlayComponent = device->GetResourceManager().Get(overlayTexture);
			const auto maxMip = std::min((int)std::floor(std::log2(std::max(overlayComponent.description.width, overlayComponent.description.height))) + 1, *CvarGet("hiZPyramidLevels", int));
			const auto sliderPad = 10.f;
			const auto sliderSize = ImVec2{ toolWindowSize.x - (style.FramePadding.x + sliderPad) * 2.f, toolWindowSize.y - viewTextSize.y - style.FramePadding.y * 2.f - style.ItemSpacing.y - 4.f };

			ImGui::SetCursorPosX(ImGui::GetCursorPosX() + sliderPad);
			ImGui::VSliderInt("", sliderSize, &hiZOverlayMip, 0, maxMip - 1);

			break;
		}

		default: break;
		}
	}

	ImGui::EndChild();

	// Render the remove overlay button.

	const char* buttonText = "Remove render overlay";
	const auto removePadding = ImGui::GetStyle().WindowPadding + ImGui::GetStyle().FramePadding;
	const auto overlayRemoveSize = ImGui::CalcTextSize(buttonText) + removePadding * 2.f + ImVec2{ 8.f, 8.f };

	ImGui::SetNextWindowPos(max - overlayRemoveSize - ImVec2{ 18, 18 });
	if (ImGui::BeginChildFrame(ImGui::GetID("Render Overlay Remove"), overlayRemoveSize, toolsWindowFlags))
	{
		auto style = ImGui::GetStyle();

		if (ImGui::Button(buttonText))
		{
			renderOverlayOnScene = false;
		}
	}

	ImGui::EndChildFrame();
}

void EditorUI::DrawRenderOverlayProxy(RenderDevice* device, const ImVec2& min, const ImVec2& max)
{
	if (renderOverlayOnScene && activeOverlay != RenderOverlay::None)
	{
		auto& style = ImGui::GetStyle();

		const auto proxyWindowFlags =
			ImGuiWindowFlags_NoDecoration |
			ImGuiWindowFlags_NoScrollWithMouse |
			ImGuiWindowFlags_NoBackground |
			ImGuiWindowFlags_NoSavedSettings |
			ImGuiWindowFlags_NoFocusOnAppearing |
			ImGuiWindowFlags_NoNav |
			ImGuiWindowFlags_NoInputs |
			ImGuiWindowFlags_NoDocking;

		ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, { 0, 0 });
		ImGui::BeginChildFrame(ImGui::GetID("Render Overlay Proxy"), { 0, 0 }, proxyWindowFlags);
		ImGui::PopStyleVar();  // Don't affect the tools window.

		auto* window = ImGui::GetCurrentWindow();

		ImGui::Image(device, overlayTexture, { 1.f, 1.f }, { sceneWidthUV, sceneHeightUV }, { 1.f + sceneWidthUV, 1.f + sceneHeightUV }, { 1.f, 1.f, 1.f, overlayAlpha });

		DrawRenderOverlayTools(device, min, max);

		ImGui::EndChildFrame();
	}
}

bool EditorUI::ExecuteCommand(const std::string& command)
{
	const auto assignment = command.find('=');
	const auto call = command.find("()");
	if (assignment == std::string::npos && call == std::string::npos)
	{
		return false;
	}

	const auto strip = [](const auto& str)
	{
		std::string result = str;
		const auto start = str.find_first_not_of(' ');
		const auto end = str.find_last_not_of(' ');
		if (end != std::string::npos)
		{
			result.erase(end + 1);
		}
		if (start != std::string::npos)
		{
			result.erase(0, start);
		}

		return result;
	};

	std::string cvar;
	std::string data;
	if (assignment != std::string::npos)
	{
		cvar = strip(command.substr(0, assignment));
		data = strip(command.substr(assignment + 1));
	}
	else
		cvar = strip(command.substr(0, call));

	if (cvar.size() == 0 || (assignment != std::string::npos && data.size() == 0))
	{
		return false;
	}

	std::transform(cvar.begin(), cvar.end(), cvar.begin(), [](auto c)
	{
		return std::tolower(c);
	});

	std::optional<const Cvar*> cvarData;

	// Search for the proper capitalization.
	for (const auto& [key, cvarIt] : CvarManager::Get().cvars)
	{
		auto cvarName = cvarIt.name;
		std::transform(cvarName.begin(), cvarName.end(), cvarName.begin(), [](auto c)
		{
			return std::tolower(c);
		});

		if (cvarName == cvar)
		{
			cvarData = &cvarIt;
			break;
		}
	}

	if (!cvarData)
	{
		return false;
	}

	std::stringstream dataStream;
	dataStream << data;

	switch ((*cvarData)->type)
	{
	case Cvar::CvarType::Int:
	{
		int data;
		dataStream >> data;
		CvarManager::Get().SetVariable(entt::hashed_string::value((*cvarData)->name.c_str(), (*cvarData)->name.size()), data);
		break;
	}
	case Cvar::CvarType::Float:
	{
		float data;
		dataStream >> data;
		CvarManager::Get().SetVariable(entt::hashed_string::value((*cvarData)->name.c_str(), (*cvarData)->name.size()), data);
		break;
	}
	case Cvar::CvarType::Function:
	{
		CvarManager::Get().ExecuteVariable(entt::hashed_string::value((*cvarData)->name.c_str(), (*cvarData)->name.size()));
		break;
	}
	default:
		VGLogError(logEditor, "Attempted to execute cvar command with unknown type {}", (*cvarData)->type);
		return false;
	}

	return true;
}

void EditorUI::DrawConsole(entt::registry& registry, const ImVec2& min, const ImVec2& max)
{
	consoleClosedThisFrame = false;

	auto& io = ImGui::GetIO();
	static bool newPress = true;
	if (ImGui::IsKeyPressed(ImGuiKey_F2))
	{
		if (newPress)
		{
			consoleClosedThisFrame = consoleOpen;
			consoleOpen = !consoleOpen;
			newPress = false;
		}
	}
	else
	{
		newPress = true;
	}

	if (consoleOpen)
	{
		auto& style = ImGui::GetStyle();
		auto windowMin = min;
		auto windowMax = max;

		ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 0);

		// Limit the height.
		constexpr auto heightMax = 220.f;
		const auto height = std::min(max.y - min.y, heightMax);
		windowMax.y = windowMin.y + height;

		constexpr auto frameColor = IM_COL32(20, 20, 20, 238);
		constexpr auto frameColorDark = IM_COL32(20, 20, 20, 242);
		ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, { 0, 0 });
		ImGui::PushStyleColor(ImGuiCol_FrameBg, frameColor);
		ImGui::PushStyleColor(ImGuiCol_ScrollbarBg, IM_COL32(0, 0, 0, 0));
		
		if (ImGui::BeginChildFrame(ImGui::GetID("Console History"), { windowMax.x - windowMin.x, height }, ImGuiWindowFlags_NoMove))
		{
			auto* window = ImGui::GetCurrentWindow();

			ImGui::SetWindowFontScale(0.8f);
			for (const auto& message : consoleMessages)
			{
				ImGui::Text("%s", message.c_str());
			}
			ImGui::SetWindowFontScale(1.f);

			if (needsScrollUpdate)
			{
				ImGui::SetScrollHereY(1.f);
				needsScrollUpdate = false;
			}

			consoleFullyScrolled = ImGui::GetCursorPosY() - ImGui::GetScrollY() < 300.f;  // Near the bottom, autoscroll.
		}

		ImGui::EndChildFrame();
		ImGui::PopStyleColor();
		ImGui::PopStyleColor();
		ImGui::PopStyleVar();

		const auto inputBoxSize = 25.f;

		static char buffer[256] = { 0 };  // Input box text buffer.

		std::vector<std::pair<const Cvar*, size_t>> cvarMatches;
		if (buffer[0] != '\0')
		{
			std::string bufferStr = buffer;
			std::transform(bufferStr.begin(), bufferStr.end(), bufferStr.begin(), [](auto c)
			{
				return std::tolower(c);
			});

			for (const auto& [key, cvar] : CvarManager::Get().cvars)
			{
				auto cvarName = cvar.name;
				std::transform(cvarName.begin(), cvarName.end(), cvarName.begin(), [](auto c)
				{
					return std::tolower(c);
				});

				if (const auto pos = cvarName.find(bufferStr); pos != std::string::npos)
				{
					cvarMatches.emplace_back(&cvar, pos);
				}
			}
		}

		ImGui::PushStyleColor(ImGuiCol_FrameBg, frameColorDark);
		ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, { 2, 2 });
		ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, { 2, 0 });

		if (ImGui::BeginChildFrame(ImGui::GetID("Console Input"), { windowMax.x - windowMin.x, inputBoxSize }, ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse))
		{
			const auto textBarStart = ImGui::GetCursorPos() + ImGui::GetWindowPos();

			// Draw hint triangle.
			const auto spacing = 6.f;
			const auto offset = 2.f;
			const auto p1 = ImVec2{ textBarStart.x + spacing, textBarStart.y + spacing - offset };
			const auto p2 = ImVec2{ textBarStart.x + spacing, textBarStart.y - spacing + inputBoxSize - offset };
			const auto p3 = ImVec2{ textBarStart.x - spacing + inputBoxSize, textBarStart.y + spacing + (inputBoxSize - 2.f * spacing) * 0.5f - offset };
			ImGui::GetWindowDrawList()->AddTriangleFilled(p1, p2, p3, IM_COL32(255, 255, 255, 245));

			const auto textCallback = [](ImGuiInputTextCallbackData* data) -> int
			{
				switch (data->EventFlag)
				{
				case ImGuiInputTextFlags_CallbackCompletion:
				{
					const char* wordEnd = data->Buf + data->CursorPos;
					const char* wordStart = wordEnd;
					while (wordStart > data->Buf)
					{
						const char c = wordStart[-1];
						if (c == ' ' || c == '\t' || c == ',' || c == ';')
							break;
						--wordStart;
					}

					// Raw matches are all possible, but autocomplete should only factor in matches that are currently equivalent.
					// Exception to this is one raw match with no exact match.
					const auto* rawMatches = (std::vector<std::pair<const Cvar*, size_t>>*)data->UserData;
					std::vector<std::string> matches;
					matches.reserve(rawMatches->size());
					for (const auto& match : *rawMatches)
					{
						if (match.second == 0)
							matches.emplace_back(match.first->name);
					}

					// Autocomplete to partial match.
					if (matches.size() == 0 && rawMatches->size() == 1)
					{
						matches.emplace_back(rawMatches->at(0).first->name);
					}

					if (matches.size() == 1)
					{
						data->DeleteChars((int)(wordStart - data->Buf), (int)(wordEnd - wordStart));
						data->InsertChars(data->CursorPos, matches[0].c_str());

						// If the cvar is a function, add (), otherwise add a space.

						auto matchIt = std::find_if(rawMatches->begin(), rawMatches->end(), [&matches](auto it)
						{
							return it.first->name == matches[0];
						});
						VGAssert(matchIt != rawMatches->end(), "Failed to find Cvar match in autocomplete.");
						const auto match = matchIt->first;

						if (match->type == Cvar::CvarType::Function)
						{
							data->InsertChars(data->CursorPos, "()");
						}
						else
						{
							data->InsertChars(data->CursorPos, " ");
						}
					}

					else if (matches.size() > 1)
					{
						int matchLength = wordEnd - wordStart;
						while (true)
						{
							int c = 0;
							bool allCandidatesMatches = true;
							for (int i = 0; i < matches.size() && allCandidatesMatches; ++i)
							{
								if (i == 0)
									c = toupper(matches[i][matchLength]);
								else if (c == 0 || c != toupper(matches[i][matchLength]))
									allCandidatesMatches = false;
							}
							if (!allCandidatesMatches)
								break;
							++matchLength;
						}

						if (matchLength > 0)
						{
							data->DeleteChars((int)(wordStart - data->Buf), (int)(wordEnd - wordStart));
							const auto matchString = matches[0].c_str();
							data->InsertChars(data->CursorPos, matchString, matchString + matchLength);
						}
					}

					break;
				}

				case ImGuiInputTextFlags_CallbackHistory:
				{
					// #TODO: History if empty, otherwise autocomplete.

					break;
				}
				}

				return 0;
			};

			const float hintSpacing = style.ItemSpacing.x + 25.f;
			ImGui::SetCursorPosX(hintSpacing);
			
			if (ImGui::IsWindowAppearing() || ImGui::IsItemDeactivatedAfterEdit())
			{
				registry.clear<ControlComponent>();
				ImGui::SetKeyboardFocusHere();
				consoleInputFocus = true;
			}

			ImGui::SetItemDefaultFocus();
			
			const auto inputFlags = ImGuiInputTextFlags_AutoSelectAll |
				ImGuiInputTextFlags_EnterReturnsTrue |
				ImGuiInputTextFlags_CallbackCompletion |
				ImGuiInputTextFlags_CallbackHistory;
			if (ImGui::InputTextEx("##", "", buffer, std::size(buffer), { windowMax.x - windowMin.x - hintSpacing, 0 }, inputFlags, textCallback, (void*)&cvarMatches))
			{
				if (ExecuteCommand(buffer))
				{
					buffer[0] = '\0';  // Clear the field.
					needsScrollUpdate = true;
				}
			}

			// If the user unfocuses the input box, then IsItemDeactivated() will be 0 for a frame.
			// We need to lock out the recapture feature until the console is closed and reopened in this case.
			consoleInputFocus &= !ImGui::IsItemDeactivated() || ImGui::IsItemDeactivatedAfterEdit();
		}

		ImGui::EndChildFrame();
		ImGui::PopStyleVar();
		ImGui::PopStyleVar();

		const auto entries = cvarMatches.size();
		if (entries > 0)
		{
			const auto entrySize = ImGui::CalcTextSize("Dummy").y + style.ItemSpacing.y;
			const auto autocompBoxMaxHeight = entrySize * 4;
			const auto autocompBoxSize = std::min(entries * entrySize + 2.f * style.FramePadding.y, autocompBoxMaxHeight);

			if (ImGui::BeginChildFrame(ImGui::GetID("Console Autocomplete"), { 0, autocompBoxSize }))
			{
				const char* typeMap[] = {
					"Int",
					"Float",
					"Function"
				};

				for (const auto cvar : cvarMatches)
				{
					const auto lineStart = ImGui::GetCursorPosX();
					ImGui::Text(cvar.first->name.c_str());
					ImGui::SameLine();

					const auto cvarName = cvar.first->name.c_str();
					const auto cvarSize = cvar.first->name.size();

					switch (cvar.first->type)
					{
					case Cvar::CvarType::Int:
					{
						if (auto cvarValue = CvarManager::Get().GetVariable<int>(entt::hashed_string::value(cvarName, cvarSize)); cvarValue)
						{
							std::stringstream valueStream;
							valueStream << *cvarValue;
							ImGui::TextDisabled("= %s", valueStream.str().c_str());
							ImGui::SameLine();
						}
						break;
					}
					case Cvar::CvarType::Float:
					{
						if (auto cvarValue = CvarManager::Get().GetVariable<float>(entt::hashed_string::value(cvarName, cvarSize)); cvarValue)
						{
							std::stringstream valueStream;
							valueStream << *cvarValue;
							ImGui::TextDisabled("= %s", valueStream.str().c_str());
							ImGui::SameLine();
						}
						break;
					}
					case Cvar::CvarType::Function:
					{
						if (auto cvarValue = CvarManager::Get().GetVariable<CvarCallableType>(entt::hashed_string::value(cvarName, cvarSize)); cvarValue)
						{
							ImGui::TextDisabled("= <function>");
							ImGui::SameLine();
						}
						break;
					}
					}

					ImGui::SetCursorPosX(lineStart + 350.f);
					ImGui::TextDisabled(typeMap[(uint32_t)cvar.first->type]);
					ImGui::SameLine();
					ImGui::SetCursorPosX(lineStart + 430.f);
					ImGui::TextDisabled(cvar.first->description.c_str());
				}
			}

			ImGui::EndChildFrame();
		}

		ImGui::PopStyleColor();
		ImGui::PopStyleVar();
	}
}

void EditorUI::Update()
{
	if (fullscreen != Renderer::Get().window->IsFullscreen())
	{
		const auto [width, height] = Renderer::Get().GetResolution();
		Renderer::Get().window->SetSize(width, height, fullscreen);
	}
}

void EditorUI::DrawLayout()
{
	auto* viewport = ImGui::GetMainViewport();
	ImGui::SetNextWindowPos(viewport->WorkPos);
	ImGui::SetNextWindowSize(viewport->WorkSize);
	ImGui::SetNextWindowViewport(viewport->ID);

	ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 0.f);
	ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.f);
	ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, { 0.f, 0.f });

	// Always draw the dock space.
	ImGui::Begin("Dock Space", nullptr,
		ImGuiWindowFlags_NoTitleBar |
		ImGuiWindowFlags_NoCollapse |
		ImGuiWindowFlags_NoResize |
		ImGuiWindowFlags_NoMove |
		ImGuiWindowFlags_NoBringToFrontOnFocus |
		ImGuiWindowFlags_NoNavFocus |
		ImGuiWindowFlags_MenuBar |
		ImGuiWindowFlags_NoDocking);

	ImGui::PopStyleVar(3);

	const auto dockSpaceId = ImGui::GetID("DockSpace");

	// Build the default dock layout if the user hasn't overriden it themselves.
	if (!ImGui::DockBuilderGetNode(dockSpaceId))
	{
		ImGui::DockBuilderRemoveNode(dockSpaceId);
		ImGui::DockBuilderAddNode(dockSpaceId, ImGuiDockNodeFlags_None);

		ImGuiID sceneDockId = 0;
		ImGuiID controlsDockId = 0;
		ImGuiID entitiesDockId = 0;
		ImGuiID propertiesDockId = 0;
		ImGuiID metricsDockId = 0;
		
		sceneDockId = ImGui::DockBuilderSplitNode(dockSpaceId, ImGuiDir_Left, 0.75f, nullptr, &controlsDockId);
		entitiesDockId = ImGui::DockBuilderSplitNode(controlsDockId, ImGuiDir_Up, 0.4f, nullptr, &propertiesDockId);
		controlsDockId = ImGui::DockBuilderSplitNode(entitiesDockId, ImGuiDir_Up, 0.19f, nullptr, &entitiesDockId);
		propertiesDockId = ImGui::DockBuilderSplitNode(propertiesDockId, ImGuiDir_Up, 0.8f, nullptr, &metricsDockId);

		ImGui::DockBuilderDockWindow("Scene", sceneDockId);
		ImGui::DockBuilderDockWindow("Controls", controlsDockId);
		ImGui::DockBuilderDockWindow("Entity Hierarchy", entitiesDockId);
		ImGui::DockBuilderDockWindow("Property Viewer", propertiesDockId);
		ImGui::DockBuilderDockWindow("Metrics", metricsDockId);
		ImGui::DockBuilderDockWindow("Render Graph", propertiesDockId);
		ImGui::DockBuilderDockWindow("Sky Atmosphere", entitiesDockId);
		ImGui::DockBuilderDockWindow("Bloom", entitiesDockId);
		ImGui::DockBuilderDockWindow("Render Visualizer", propertiesDockId);
		ImGui::DockBuilderDockWindow("Dear ImGui Demo", sceneDockId);
		
		ImGui::DockBuilderFinish(dockSpaceId);
	}

	ImGui::DockSpace(dockSpaceId, { 0.f, 0.f });

	// Draw the menu in the dock space window.
	DrawMenu();

	ImGui::End();
}

void EditorUI::DrawDemoWindow()
{
	static bool demoWindowOpen = true;

	ImGui::ShowDemoWindow(&demoWindowOpen);
}

void EditorUI::DrawScene(RenderDevice* device, entt::registry& registry, TextureHandle sceneTexture)
{
	const auto& sceneDescription = device->GetResourceManager().Get(sceneTexture).description;

	ImGui::SetNextWindowSizeConstraints({ 100.f, 100.f }, { (float)sceneDescription.width, (float)sceneDescription.height });

	ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, { 0.f, 0.f });  // Remove window padding.

	if (ImGui::Begin("Scene", nullptr, ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse | ImGuiWindowFlags_NoCollapse))
	{
		const auto viewportMin = ImGui::GetWindowContentRegionMin();
		const auto viewportMax = ImGui::GetWindowContentRegionMax();
		const auto viewportSize = viewportMax - viewportMin;
		const auto widthUV = (1.f - (viewportSize.x / sceneDescription.width)) * 0.5f;
		const auto heightUV = (1.f - (viewportSize.y / sceneDescription.height)) * 0.5f;

		sceneWidthUV = widthUV;
		sceneHeightUV = heightUV;
		sceneViewportMin = ImGui::GetWindowPos() + ImGui::GetWindowContentRegionMin();
		sceneViewportMax = ImGui::GetWindowPos() + ImGui::GetWindowContentRegionMax();

		ImGui::Image(device, sceneTexture, { 1.f, 1.f }, { widthUV, heightUV }, { 1.f + widthUV, 1.f + heightUV });

		// Double clicking the viewport grants control.
		const bool shouldReacquireControl = consoleClosedThisFrame && consoleInputFocus;
		if ((ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left) && ImGui::IsWindowHovered(ImGuiHoveredFlags_None)) || shouldReacquireControl)
		{
			// #TODO: Grant control to only the camera that the viewport is linked to, not every camera-owning entity.
			registry.view<const CameraComponent>().each([&](auto entity, const auto&)
			{
				if (!registry.all_of<ControlComponent>(entity))
				{
					registry.emplace<ControlComponent>(entity);
				}
			});
		}

		// Use a dummy object to get proper drag drop bounds.
		const float padding = 4.f;
		ImGui::SetCursorPos(ImGui::GetWindowContentRegionMin() + ImVec2{ padding, padding });
		ImGui::Dummy(ImGui::GetWindowContentRegionMax() - ImGui::GetWindowContentRegionMin() - ImVec2{ padding * 2.f, padding * 2.f });

		if (ImGui::BeginDragDropTarget())
		{
			if (const auto* payload = ImGui::AcceptDragDropPayload("RenderOverlay", ImGuiDragDropFlags_None))
			{
				renderOverlayOnScene = true;
			}

			ImGui::EndDragDropTarget();
		}

		ImGui::SetCursorPos(viewportMin);
		DrawRenderOverlayProxy(device, sceneViewportMin, sceneViewportMax);

		if (showFps && frameTimes.size() > 0)
		{
			auto& style = ImGui::GetStyle();

			ImGui::SetWindowFontScale(1.5f);

			const auto fpsTextSize = ImGui::CalcTextSize("FPS: 000.0");
			const auto fpsTextPosition = ImVec2{ viewportMax.x - fpsTextSize.x - 40.f, viewportMin.y + 40.f };
			ImGui::SetCursorPos(fpsTextPosition);

			const auto border = 2.f;
			const auto offset = 2.f;
			const auto screenOffset = ImGui::GetWindowPos();
			const auto frameMin = ImVec2{ fpsTextPosition.x - border - 4.f, fpsTextPosition.y - border - offset };
			const auto frameMax = ImVec2{ fpsTextPosition.x + fpsTextSize.x + border + 4.f, fpsTextPosition.y + fpsTextSize.y + border - offset };
			auto frameColor = ImGui::GetColorU32(ImGuiCol_FrameBg, 0.85f);
			ImGui::RenderFrame(screenOffset + frameMin, screenOffset + frameMax, frameColor, true);

			const auto fps = 1000000.f / frameTimes.back();
			auto textColor = IM_COL32(0, 255, 0, 255);
			if (fps < 30.f)
				textColor = IM_COL32(255, 0, 0, 255);
			else if (fps < 60.f)
				textColor = IM_COL32(252, 86, 3, 255);
			ImGui::PushStyleColor(ImGuiCol_Text, textColor);
			ImGui::Text("FPS: %.1f", fps);
			ImGui::PopStyleColor();
			ImGui::SetWindowFontScale(1.f);
		}

		ImGui::SetCursorPos(viewportMin);
		DrawConsole(registry, sceneViewportMin, sceneViewportMax);
	}

	ImGui::End();

	ImGui::PopStyleVar();
}

void EditorUI::DrawControls(RenderDevice* device)
{
	if (controlsOpen)
	{
		if (ImGui::Begin("Controls", &controlsOpen))
		{
			if (ImGui::Button("Reload Shaders"))
			{
				Renderer::Get().ReloadShaderPipelines();
			}

			CvarHelpers::Checkbox("toneMappingEnabled", "Tone mapping");
		}

		ImGui::End();
	}
}

void EditorUI::DrawEntityHierarchy(entt::registry& registry)
{
	if (entityHierarchyOpen)
	{
		entt::entity selectedEntity = entt::null;

		if (ImGui::Begin("Entity Hierarchy", &entityHierarchyOpen))
		{
			ImGui::Text("%i Entities", registry.size());
			ImGui::Separator();

			registry.each([this, &registry, &selectedEntity](auto entity)
			{
				ImGuiTreeNodeFlags nodeFlags = ImGuiTreeNodeFlags_None;

				if (entity == hierarchySelectedEntity)
					nodeFlags |= ImGuiTreeNodeFlags_Selected;

				bool nodeOpen = false;

				ImGui::PushID(static_cast<int32_t>(entity));  // Use the entity as the ID.

				if (registry.all_of<NameComponent>(entity))
				{
					nodeOpen = ImGui::TreeNodeEx("EntityTreeNode", nodeFlags, registry.get<NameComponent>(entity).name.c_str());
				}

				else
				{
					// Strip the version info from the entity, we only care about the actual ID.
					nodeOpen = ImGui::TreeNodeEx("EntityTreeNode", nodeFlags, "Entity_%i", registry.entity(entity));
				}

				if (ImGui::IsItemClicked())
				{
					selectedEntity = entity;
				}

				if (nodeOpen)
				{
					// #TODO: Draw entity children.

					ImGui::TreePop();
				}

				ImGui::PopID();

				// Open the property viewer with focus on left click. Test the condition for each tree node.
				if (ImGui::IsMouseDoubleClicked(ImGuiMouseButton_Left) && ImGui::IsItemHovered(ImGuiHoveredFlags_None))
				{
					entityPropertyViewerOpen = true;
					entityPropertyViewerFocus = true;
				}
			});
		}

		ImGui::End();

		// Check if it's valid first, otherwise deselecting will remove the property viewer.
		if (registry.valid(selectedEntity))
		{
			hierarchySelectedEntity = selectedEntity;
		}
	}
}

void EditorUI::DrawEntityPropertyViewer(entt::registry& registry)
{
	if (entityPropertyViewerOpen)
	{
		if (entityPropertyViewerFocus)
		{
			entityPropertyViewerFocus = false;
			ImGui::SetNextWindowFocus();
		}

		if (ImGui::Begin("Property Viewer", &entityPropertyViewerOpen))
		{
			if (registry.valid(hierarchySelectedEntity))
			{
				uint32_t componentCount = 0;

				for (auto& [metaID, renderFunction] : EntityReflection::componentList)
				{
					entt::id_type metaList[] = { metaID };

					if (registry.runtime_view(std::cbegin(metaList), std::cend(metaList)).contains(hierarchySelectedEntity))
					{
						++componentCount;

						ImGui::PushID(metaID);
						renderFunction(registry, hierarchySelectedEntity);
						ImGui::PopID();

						ImGui::Separator();
					}
				}

				if (componentCount == 0)
				{
					ImGui::Text("No components.");
				}
			}

			else
			{
				const auto windowWidth = ImGui::GetWindowSize().x;
				const auto text = "No entity selected.";
				const auto textWidth = ImGui::CalcTextSize(text).x;

				ImGui::SetCursorPosX((windowWidth - textWidth) * 0.5f);
				ImGui::SetCursorPosY(ImGui::GetCursorPosY() + 10.f);
				ImGui::TextDisabled(text);
			}
		}

		ImGui::End();
	}
}

void EditorUI::DrawMetrics(RenderDevice* device, float frameTimeMs)
{
	frameTimes.push_back(frameTimeMs);

	while (frameTimes.size() > frameTimeHistoryCount)
	{
		frameTimes.pop_front();
	}

	if (metricsOpen)
	{
		if (ImGui::Begin("Metrics", &metricsOpen))
		{
			DrawFrameTimeHistory();

			const auto memoryInfo = device->GetResourceManager().QueryMemoryInfo();

			ImGui::Separator();
			ImGui::Text("GPU Memory");

			ImGui::Text("Buffers (%u objects): %.2f MB", memoryInfo.bufferCount, memoryInfo.bufferBytes / (1024.f * 1024.f));
			ImGui::Text("Textures (%u objects): %.2f MB", memoryInfo.textureCount, memoryInfo.textureBytes / (1024.f * 1024.f));
		}

		ImGui::End();
	}
}

void EditorUI::DrawRenderGraph(RenderDevice* device, RenderGraphResourceManager& resourceManager, TextureHandle depthStencil, TextureHandle scene)
{
	if (renderGraphOpen)
	{
		if (ImGui::Begin("Render Graph", &renderGraphOpen))
		{
			if (ImGui::CollapsingHeader("Settings", ImGuiTreeNodeFlags_DefaultOpen))
			{
				ImGui::Checkbox("Linearize depth", &linearizeDepth);
				ImGui::Checkbox("Allow transient resource reuse", &resourceManager.transientReuse);
			}

			if (linearizeDepth)
			{
				ImGui::GetWindowDrawList()->AddCallback([](auto* list, auto& state)
				{
					state.linearizeDepth = true;
				}, nullptr);
			}

			ImGui::Image(device, depthStencil, { 0.25f, 0.25f });

			if (linearizeDepth)
			{
				ImGui::GetWindowDrawList()->AddCallback([](auto* list, auto& state)
				{
					state.linearizeDepth = false;
				}, nullptr);
			}

			ImGui::Image(device, scene, { 0.25f, 0.25f });
		}

		ImGui::End();
	}
}

void EditorUI::DrawAtmosphereControls(RenderDevice* device, entt::registry& registry, Atmosphere& atmosphere, Clouds& clouds, TextureHandle weather)
{
	if (atmosphereControlsOpen)
	{
		if (ImGui::Begin("Sky Atmosphere", &atmosphereControlsOpen))
		{
			ImGui::Text("General");
			ComponentProperties::RenderTimeOfDayComponent(registry, atmosphere.sunLight);
			CvarHelpers::Checkbox("farVolumetricShadowFix", "Far volume shadow fix enabled");

			ImGui::Separator();

			ImGui::Text("Weather");
			ImGui::DragFloat("Cloud coverage", &clouds.coverage, 0.005f, 0.f, 1.f);
			ImGui::DragFloat("Precipitation", &clouds.precipitation, 0.005f, 0.f, 1.f);
			ImGui::DragFloat("Wind strength", &clouds.windStrength, 0.01f, 0.f, 1.f);
			ImGui::DragFloat2("Wind direction", (float*)&clouds.windDirection, 0.01f, -1.f, 1.f);

			ImGui::Image(device, weather, { 0.1f, 0.1f });

			ImGui::Separator();

			ImGui::Text("Clouds");
			CvarHelpers::Checkbox("cloudRayMarchQuality", "Ray march ground truth");
			CvarHelpers::Checkbox("renderLightShafts", "Render light shafts");
			CvarHelpers::Slider("cloudRenderScale", "Render scale", 0.1f, 1.f);
			CvarHelpers::Slider("cloudShadowRenderScale", "Shadow render scale", 0.1f, 1.f);
			CvarHelpers::Checkbox("cloudBlurEnabled", "Blur enabled");
			CvarHelpers::Slider("cloudBlurRadius", "Blur radius", 1, 8);

			ImGui::Separator();

			ImGui::Text("Atmosphere");
			bool dirty = false;
			static float haze = 8;
			static float lastHaze = -1;

			ImGui::TextDisabled("Presets");
			if (ImGui::Button("Clear sky"))
				haze = 0;
			ImGui::SameLine();
			if (ImGui::Button("Light haze"))
				haze = 18;
			ImGui::SameLine();
			if (ImGui::Button("Heavy haze"))
				haze = 80;

			ImGui::DragFloat("Haze", &haze, 0.5f, 0.f, 100.f);

			if (haze != lastHaze)
				dirty = true;
			lastHaze = haze;

			// Only compute model coefficients if we modified the haze factor.
			if (dirty)
			{
				const auto epsilon = 0.00000001f;
				const auto defaultMie = 0.003996f * 1.2f;
				const auto newMie = haze * defaultMie + epsilon;
				atmosphere.model.mieScattering = { newMie, newMie, newMie };
				atmosphere.model.mieExtinction = { 1.11f * newMie, 1.11f * newMie, 1.11f * newMie };
			}

			ImGui::TextDisabled("Model");
			dirty |= ImGui::DragFloat("Bottom radius", &atmosphere.model.radiusBottom, 0.2f, 1.f, atmosphere.model.radiusTop, "%.3f");
			dirty |= ImGui::DragFloat("Top radius", &atmosphere.model.radiusTop, 0.2f, atmosphere.model.radiusBottom, 10000.f, "%.3f");
			dirty |= ImGui::DragFloat3("Rayleigh scattering", (float*)&atmosphere.model.rayleighScattering, 0.001f, 0.f, 1.f, "%.6f");
			dirty |= ImGui::DragFloat3("Mie scattering", (float*)&atmosphere.model.mieScattering, 0.001f, 0.f, 1.f, "%.6f");
			dirty |= ImGui::DragFloat3("Mie extinction", (float*)&atmosphere.model.mieExtinction, 0.001f, 0.f, 1.f, "%.6f");
			dirty |= ImGui::DragFloat3("Absorption extinction", (float*)&atmosphere.model.absorptionExtinction, 0.001f, 0.f, 1.f, "%.6f");
			dirty |= ImGui::DragFloat3("Surface color", (float*)&atmosphere.model.surfaceColor, 0.01f, 0.f, 1.f, "%.3f");
			dirty |= ImGui::DragFloat3("Solar irradiance", (float*)&atmosphere.model.solarIrradiance, 0.01f, 0.f, 100.f, "%.4f");

			if (dirty)
			{
				atmosphere.MarkModelDirty();
			}
		}

		ImGui::End();
	}
}

void EditorUI::DrawBloomControls(Bloom& bloom)
{
	if (bloomControlsOpen)
	{
		if (ImGui::Begin("Bloom", &bloomControlsOpen))
		{
			ImGui::DragFloat("Intensity", &bloom.intensity, 0.01f, 0.f, 1.f, "%.2f");
			ImGui::DragFloat("Internal blend", &bloom.internalBlend, 0.01f, 0.f, 1.f, "%.2f");
		}

		ImGui::End();
	}
}

void EditorUI::DrawRenderVisualizer(RenderDevice* device, ClusteredLightCulling& clusteredCulling, TextureHandle overlay)
{
	// We don't draw the overlay until the next frame, so just save it here.
	// #TODO: Bit of a scuffed solution, and causing a crash sometimes when changing overlays!
	overlayTexture = overlay;

	if (renderVisualizerOpen)
	{
		if (ImGui::Begin("Render Visualizer", &renderVisualizerOpen))
		{
			ImGui::Combo("Active overlay", (int*)&activeOverlay, [](void*, int index, const char** output)
			{
				auto overlay = (RenderOverlay)index;

				switch (overlay)
				{
				case RenderOverlay::None: *output = "None"; break;
				case RenderOverlay::Clusters: *output = "Clusters"; break;
				case RenderOverlay::HiZ: *output = "Hierarchical Depth Pyramid"; break;
				default: return false;
				}

				return true;
			}, nullptr, 3);  // Note: Make sure to update the hardcoded count when new overlays are added.

			ImGui::Separator();

			if (activeOverlay != RenderOverlay::None)
			{
				if (!renderOverlayOnScene)
				{
					ImGui::Text("Drag the overlay onto the scene to view.");

					ImGui::ImageButton(device, overlay, { 0.25f, 0.25f });

					if (ImGui::BeginDragDropSource(ImGuiDragDropFlags_None))
					{
						ImGui::SetDragDropPayload("RenderOverlay", nullptr, 0);

						ImGui::ImageButton(device, overlay, { 0.1f, 0.1f }, { 0.f, 0.f }, { 1.f, 1.f }, { 1.f, 1.f, 1.f, 0.5f });

						ImGui::EndDragDropSource();
					}
				}

				else
				{
					ImGui::Text("Overlay enabled.");
				}
			}

			else
			{
				ImGui::Text("No active overlay.");
			}

			ImGui::SliderFloat("Overlay alpha", &overlayAlpha, 0.05f, 1.f, "%.2f");
		}

		ImGui::End();
	}
}

void EditorUI::AddConsoleMessage(const std::string& message)
{
	consoleMessages.push_back(message);

	if (consoleFullyScrolled)
	{
		needsScrollUpdate = true;
	}
}