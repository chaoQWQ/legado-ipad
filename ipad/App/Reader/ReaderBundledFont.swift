import CoreText
import Foundation

enum ReaderBundledFont {
    static let sourceHanWeightRange: ClosedRange<Double> = 250...900

    @MainActor private static let sourceHanDescriptor: CTFontDescriptor? = {
        let resource = "SourceHanSerifCN-VF"
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: resource, withExtension: "otf")
                ?? bundle.url(forResource: resource, withExtension: "otf", subdirectory: "Fonts"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            return nil
        }

        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if let problem = error?.takeRetainedValue(),
           CFErrorGetCode(problem) == CTFontManagerError.alreadyRegistered.rawValue {
            return descriptor
        }
        return registered ? descriptor : nil
    }()

    @MainActor
    static func sourceHanSerif(size: CGFloat, weight: Double) -> CTFont? {
        guard let descriptor = sourceHanDescriptor else { return nil }
        let wght = NSNumber(value: UInt32(0x77676874))
        let value = min(sourceHanWeightRange.upperBound, max(sourceHanWeightRange.lowerBound, weight))
        let varied = CTFontDescriptorCreateCopyWithVariation(descriptor, wght, CGFloat(value))
        return CTFontCreateWithFontDescriptor(varied, size, nil)
    }
}
