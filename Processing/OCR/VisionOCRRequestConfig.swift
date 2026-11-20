import Foundation
import CoreGraphics

extension VisionOCR {
    struct RecognitionRequestConfig {
        let envelopeImageBridgeTag: String
        let envelopeImageBridgeFunction: String
        let envelopeResidualTag: String?
        let envelopeResidualFunction: String?
        let memoryTag: String
        let memoryFunction: String
        let memoryReason: String
        let privateHeapTag: String
        let privateHeapFunction: String
        let retainedHeapTag: String?
        let retainedHeapFunction: String?
        let setupResidualTag: String?
        let setupResidualFunction: String?
        let observationBridgeTag: String?
        let observationBridgeFunction: String?
        let runtimeResidualTag: String?
        let runtimeResidualFunction: String?
        let resultsGraphTag: String?
        let resultsGraphFunction: String?
        let materializationResidualTag: String?
        let materializationResidualFunction: String?
        let phaseResidualDuration: TimeInterval
        let retainedHeapDuration: TimeInterval
        let regionOfInterest: CGRect?
        let usesLanguageCorrection: Bool
    }

    static func fullFrameRecognitionRequestConfig() -> RecognitionRequestConfig {
        RecognitionRequestConfig(
            envelopeImageBridgeTag: "processing.ocr.fullFrameImageBridge",
            envelopeImageBridgeFunction: "processing.ocr.full_frame",
            envelopeResidualTag: "processing.ocr.fullFrameOuterResidual",
            envelopeResidualFunction: "processing.ocr.full_frame",
            memoryTag: "processing.ocr.fullFrameVisionRequest",
            memoryFunction: "processing.ocr.full_frame",
            memoryReason: "processing.ocr.vision_full_frame",
            privateHeapTag: "processing.ocr.fullFramePrivateHeap",
            privateHeapFunction: "processing.ocr.full_frame",
            retainedHeapTag: "processing.ocr.fullFrameRetainedHeap",
            retainedHeapFunction: "processing.ocr.full_frame",
            setupResidualTag: "processing.ocr.fullFrameRequestSetup",
            setupResidualFunction: "processing.ocr.full_frame",
            observationBridgeTag: "processing.ocr.fullFrameObservationBridge",
            observationBridgeFunction: "processing.ocr.full_frame",
            runtimeResidualTag: "processing.ocr.fullFrameRuntimeResidual",
            runtimeResidualFunction: "processing.ocr.full_frame",
            resultsGraphTag: "processing.ocr.fullFrameResultsGraph",
            resultsGraphFunction: "processing.ocr.full_frame",
            materializationResidualTag: "processing.ocr.fullFrameMaterializationResidual",
            materializationResidualFunction: "processing.ocr.full_frame",
            phaseResidualDuration: Self.transientPhaseResidualHoldSeconds,
            retainedHeapDuration: 4,
            regionOfInterest: nil,
            usesLanguageCorrection: false
        )
    }

    static func regionRecognitionRequestConfig(
        regionOfInterest: CGRect,
        usesLanguageCorrection: Bool
    ) -> RecognitionRequestConfig {
        RecognitionRequestConfig(
            envelopeImageBridgeTag: "processing.ocr.regionImageBridge",
            envelopeImageBridgeFunction: "processing.ocr.region_reocr",
            envelopeResidualTag: "processing.ocr.regionBlindResidual",
            envelopeResidualFunction: "processing.ocr.region_reocr",
            memoryTag: "processing.ocr.regionVisionRequest",
            memoryFunction: "processing.ocr.region_reocr",
            memoryReason: "processing.ocr.vision_region",
            privateHeapTag: "processing.ocr.regionPrivateHeap",
            privateHeapFunction: "processing.ocr.region_reocr",
            retainedHeapTag: "processing.ocr.regionRetainedHeap",
            retainedHeapFunction: "processing.ocr.region_reocr",
            setupResidualTag: "processing.ocr.regionRequestSetup",
            setupResidualFunction: "processing.ocr.region_reocr",
            observationBridgeTag: "processing.ocr.regionObservationBridge",
            observationBridgeFunction: "processing.ocr.region_reocr",
            runtimeResidualTag: "processing.ocr.regionRuntimeResidual",
            runtimeResidualFunction: "processing.ocr.region_reocr",
            resultsGraphTag: "processing.ocr.regionResultsGraph",
            resultsGraphFunction: "processing.ocr.region_reocr",
            materializationResidualTag: "processing.ocr.regionMaterializationResidual",
            materializationResidualFunction: "processing.ocr.region_reocr",
            phaseResidualDuration: Self.transientPhaseResidualHoldSeconds,
            retainedHeapDuration: 4,
            regionOfInterest: regionOfInterest,
            usesLanguageCorrection: usesLanguageCorrection
        )
    }
}
