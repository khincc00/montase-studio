//
//  KHCutProTests.swift
//  KHCutProTests
//
//  Created by taufiq sholikhin on 05/10/26.
//

import Foundation
import AVFoundation
import Testing
@testable import KHCutPro

struct KHCutProTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

    @Test func adjustmentLayerSurvivesProjectSerialization() throws {
        let asset = MediaAsset.container(name: "Adjustment Layer", type: .adjustment, duration: 4)
        let clip = TimelineClip(asset: asset, startTime: 2, duration: 4, lane: 2)
        let restored = try JSONDecoder().decode(TimelineClip.self, from: JSONEncoder().encode(clip))
        #expect(restored.isAdjustmentLayer)
        #expect(restored.startTime == 2)
        #expect(restored.duration == 4)
    }

    @Test func titlePresetsIncludeSocialAndSubtitleStyles() {
        let social = TitleSpec.make(.socialHook)
        let caption = TitleSpec.make(.subtitlePop)
        #expect(social.backgroundEnabled)
        #expect(social.uppercase)
        #expect(caption.isCaption)
        #expect(caption.backgroundEnabled)
    }

    @Test @MainActor func stillImagesCanBeAddedToThePrimaryTimeline() {
        let image = MediaAsset.container(name: "Still image", type: .image, duration: 0)
        let timeline = TimelineModel()
        timeline.append(image)

        #expect(image.isEditable)
        #expect(timeline.selectedClip?.asset.fileType == .image)
        #expect(timeline.selectedClip?.duration == 5)
        #expect(timeline.selectedClip?.lane == 0)
    }

    @Test @MainActor func copiedClipsPasteAtPlayheadWithFreshIDs() {
        let timeline = TimelineModel()
        timeline.addTitle(.basic, text: "Judul", duration: 3)
        let original = timeline.selectedClip
        timeline.copySelected()
        timeline.seek(to: 8)
        timeline.pasteClips()

        #expect(timeline.selectedClip?.id != original?.id)
        #expect(timeline.selectedClip?.startTime == 8)
        #expect(timeline.selectedClip?.title?.text == "Judul")
    }

    @Test @MainActor func kenBurnsAppliesSmoothPanAndZoomKeyframes() {
        let image = MediaAsset.container(name: "Foto", type: .image, duration: 0)
        let timeline = TimelineModel()
        timeline.append(image)
        let id = timeline.selectedClipID!
        timeline.applyKenBurns(to: id)

        #expect(timeline.clip(id)?.tracks[.scale]?.keys.count == 2)
        #expect(timeline.clip(id)?.tracks[.positionX]?.keys.count == 2)
        #expect(timeline.clip(id)?.tracks[.positionY]?.keys.count == 2)
    }

    @Test func h264FourKExportPresetUsesMP4() {
        #expect(ExportPreset.h2644K.fileType == .mp4)
        #expect(ExportPreset.h2644K.fileExtension == "mp4")
        #expect(ExportPreset.h2644K.avPreset == AVAssetExportPreset3840x2160)
    }

    @Test func audioRolesMapToDedicatedStudioLanes() {
        #expect(AudioRole.dialogue.lane == -1)
        #expect(AudioRole.music.lane == -2)
        #expect(AudioRole.effects.lane == -3)
        #expect(AudioRole.dialogue.laneLabel == "A1 · Dialog")
        #expect(AudioRole.music.laneLabel == "A2 · Musik")
        #expect(AudioRole.effects.laneLabel == "A3 · Efek")
    }

    @Test @MainActor func generatedCaptionsAreSelectedForInspectorEditing() {
        let timeline = TimelineModel()
        timeline.addCaptions([
            CaptionCue(start: 1, end: 2, text: "Baris pertama"),
            CaptionCue(start: 2.2, end: 3, text: "Baris kedua")
        ])

        #expect(timeline.selectedClip?.title?.isCaption == true)
        #expect(timeline.selectedClip?.title?.text == "Baris pertama")
        #expect((timeline.selectedClip?.fadeIn ?? 0) > 0)
        #expect(timeline.selectedClip?.lane == 2)
        #expect(timeline.clips.filter { $0.title?.isCaption == true }.allSatisfy { $0.lane == 2 })
    }

    @Test @MainActor func socialTitleTemplateIncludesEntranceAnimation() {
        let timeline = TimelineModel()
        timeline.addTitle(.socialHook)

        #expect(timeline.selectedClip?.tracks[.scale]?.keys.count == 3)
        #expect(timeline.selectedClip?.tracks[.opacity]?.keys.count == 2)
    }
}
