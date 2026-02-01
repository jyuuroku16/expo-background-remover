import ExpoModulesCore
import Vision
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

public class ExpoBackgroundRemoverModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoBackgroundRemover")

    AsyncFunction("removeBackground") { (imageURI: String, options: [String: Any], promise: Promise) in
      self.removeBackground(imageURI, options: options, promise: promise)
    }
  }

  private func removeBackground(_ imageURI: String, options: [String: Any], promise: Promise) {
     #if targetEnvironment(simulator)
     promise.reject("SimulatorError", "This feature is not available on simulators.")
     return
     #endif

     if #available(iOS 17.0, *) {
         let trim = options["trim"] as? Bool ?? true
         guard let url = URL(string: imageURI) else {
             promise.reject("Invalid URL", "The provided image URI is invalid.")
             return
         }
         
         guard let originalImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
             promise.reject("Unable to load image", "Could not load image from URI.")
             return
         }
         
         DispatchQueue.global(qos: .userInitiated).async {
             // Autorelease pool to promptly free intermediate CoreImage / Vision objects.
             autoreleasepool {
                 do {
                     // Create mask for foreground objects
                     guard let maskImage = self.createMask(from: originalImage) else {
                         promise.reject("Failed to create mask", "Vision failed to create a mask.")
                         return
                     }
                     
                     // Apply mask to remove background
                     let maskedImage = self.applyMask(mask: maskImage, to: originalImage)
                     
                     // Convert to UIImage (renders to CGImage)
                     let uiImage = self.convertToUIImage(ciImage: maskedImage)

                     let finalImage = trim ?
                         self.trimTransparentPixels(from: uiImage) :
                         uiImage
                     
                     // Save the image as PNG to preserve transparency
                     let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(url.lastPathComponent).appendingPathExtension("png")
                     if let data = finalImage.pngData() {
                         try data.write(to: tempURL, options: .atomic)
                         DispatchQueue.main.async { promise.resolve(tempURL.absoluteString) }
                     } else {
                         DispatchQueue.main.async { promise.reject("Error saving image", "Could not write image data.") }
                     }
                 } catch {
                     DispatchQueue.main.async { promise.reject("Error removing background", error.localizedDescription) }
                 }
             }
         }
     } else {
         // For iOS < 17.0, return a specific error code that indicates API fallback should be used
         promise.reject("REQUIRES_API_FALLBACK", "This feature requires iOS 17.0 or later.")
     }
  }
  
  // Trim transparent pixels around the image
    private func trimTransparentPixels(from image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        
        let totalPixels = cgImage.width * cgImage.height
        let coreCount = ProcessInfo.processInfo.processorCount
        
        return (totalPixels > 1000000 && coreCount >= 4) ? 
            trimTransparentPixelsParallel(from: image) : 
            trimTransparentPixelsSequential(from: image)
    }
    
    private func trimTransparentPixelsSequential(from image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let data = context.data else { return image }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * bytesPerPixel)
        
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        
        // Find bounds of non-transparent pixels
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * bytesPerPixel
                let alpha = buffer[pixelIndex + 3]
                
                // If pixel is not transparent
                if alpha > 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        
        // If no non-transparent pixels found, return a 1x1 transparent image
        guard maxX >= 0 && maxY >= 0 && minX <= maxX && minY <= maxY else {
            return UIImage()
        }
        
        // Calculate crop rect
        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        
        // Crop the image
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return image }
        
        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
    
    // Parallel implementation for large images
    private func trimTransparentPixelsParallel(from image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        
        let width = cgImage.width
        let height = cgImage.height
        let coreCount = ProcessInfo.processInfo.processorCount
        
        // Setup shared context for pixel data access
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let bitsPerComponent = 8
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        guard let data = context.data else { return image }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height * bytesPerPixel)
        
        // Use optimal number of threads based on available cores (min 4, max 8)
        let threadCount = min(max(coreCount, 4), 8)
        
        // Split into optimal number of regions based on thread count
        let quadrants: [QuadrantRect]
        if threadCount == 4 {
            // Classic 4-quadrant split for 4 cores
            let halfWidth = width / 2
            let halfHeight = height / 2
            quadrants = [
                QuadrantRect(startX: 0, startY: 0, endX: halfWidth, endY: halfHeight),           // Top-left
                QuadrantRect(startX: halfWidth, startY: 0, endX: width, endY: halfHeight),      // Top-right (gets extra width if odd)
                QuadrantRect(startX: 0, startY: halfHeight, endX: halfWidth, endY: height),     // Bottom-left (gets extra height if odd)
                QuadrantRect(startX: halfWidth, startY: halfHeight, endX: width, endY: height)  // Bottom-right (gets both extras if odd)
            ]
        } else {
            // For more cores, split into horizontal strips for better cache locality
            let stripHeight = height / threadCount
            quadrants = (0..<threadCount).map { i in
                let startY = i * stripHeight
                let endY = (i == threadCount - 1) ? height : (i + 1) * stripHeight
                return QuadrantRect(startX: 0, startY: startY, endX: width, endY: endY)
            }
        }
        
        // Process regions concurrently using GCD
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "crop.parallel", attributes: .concurrent)
        
        // Pre-allocate array for results (thread-safe access by index)
        var results = Array(repeating: QuadrantBounds(), count: threadCount)
        
        // We need a lock or careful indexing. Since we write to unique indices, it's safe if array is pre-sized.
        // Actually, we can't write to `var results` from swift closure without being careful about value type copy.
        // Array is value type. We should use UnsafeMutableBufferPointer or a class wrapper.
        // Or simpler: use a class for the result.
        
        // Refactoring original logic which used `var results` in closure which might be a capture issue if not handled right?
        // Original code:
        // var results: [QuadrantBounds] = Array(repeating: QuadrantBounds(), count: threadCount)
        // for (index, quadrant) in quadrants.enumerated() { queue.async { results[index] = ... } }
        // In Swift, `results` captured in closure is a copy if it's a value type? No, it captures reference to local var if in same scope?
        // Wait, standard Swift `async` closure captures `self` strongly, but `results`?
        // If it's a `var` local variable, the closure captures a reference to the variable box. So it should work as long as it's modified safely.
        // But concurrent modification of Array is NOT safe.
        // The original code might have been unsafe or I missed a lock?
        // Original code: `results[index] = ...` inside `queue.async`.
        // Concurrent rights to different indices of a Swift Array is technically undefined behavior / unsafe without a lock.
        // I will use `NSLock` to be safe or `UnsafeMutablePointer`.
        
        let lock = NSLock()
        
        for (index, quadrant) in quadrants.enumerated() {
            group.enter()
            queue.async {
                let bound = self.findBoundsInQuadrant(buffer: buffer, quadrant: quadrant, width: width, bytesPerPixel: bytesPerPixel)
                lock.lock()
                results[index] = bound
                lock.unlock()
                group.leave()
            }
        }
        
        group.wait()
        
        let globalBounds = mergeBounds(results: results)
        
        guard globalBounds.isValid else { 
            return UIImage() // Return empty image if no non-transparent pixels found
        }
        
        let cropRect = CGRect(x: globalBounds.minX, y: globalBounds.minY, 
                              width: globalBounds.width, height: globalBounds.height)
        
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return image }
        
        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
    }
    
    private struct QuadrantRect {
        let startX: Int
        let startY: Int
        let endX: Int
        let endY: Int
    }
    
    private struct QuadrantBounds {
        var minX: Int = Int.max
        var minY: Int = Int.max
        var maxX: Int = -1
        var maxY: Int = -1
        
        var isValid: Bool { maxX >= 0 && maxY >= 0 }
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }
    
    private func findBoundsInQuadrant(buffer: UnsafeMutablePointer<UInt8>, quadrant: QuadrantRect, width: Int, bytesPerPixel: Int) -> QuadrantBounds {
        var bounds = QuadrantBounds()
        
        // Scan only the pixels in this quadrant
        for y in quadrant.startY..<quadrant.endY {
            for x in quadrant.startX..<quadrant.endX {
                let pixelIndex = (y * width + x) * bytesPerPixel
                let alpha = buffer[pixelIndex + 3]
                
                // If pixel is not transparent
                if alpha > 0 {
                    if x < bounds.minX { bounds.minX = x }
                    if x > bounds.maxX { bounds.maxX = x }
                    if y < bounds.minY { bounds.minY = y }
                    if y > bounds.maxY { bounds.maxY = y }
                }
            }
        }
        
        return bounds
    }
    
    private func mergeBounds(results: [QuadrantBounds]) -> QuadrantBounds {
        let validResults = results.filter { $0.isValid }
        
        guard !validResults.isEmpty else {
            return QuadrantBounds() // Invalid bounds
        }
        
        var merged = QuadrantBounds()
        merged.minX = validResults.map { $0.minX }.min() ?? Int.max
        merged.minY = validResults.map { $0.minY }.min() ?? Int.max
        merged.maxX = validResults.map { $0.maxX }.max() ?? -1
        merged.maxY = validResults.map { $0.maxY }.max() ?? -1
        
        return merged
    }
    
    // Create mask using VNGenerateForegroundInstanceMaskRequest for any foreground objects
    @available(iOS 17.0, *)
    private func createMask(from inputImage: CIImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: inputImage)
        
        do {
            try handler.perform([request])
            
            if let result = request.results?.first {
                let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
                return CIImage(cvPixelBuffer: mask)
            }
        } catch {
            print("Error creating mask: \(error)")
        }
        
        return nil
    }
    
    // Apply mask to image using CIFilter.blendWithMask
    @available(iOS 17.0, *)
    private func applyMask(mask: CIImage, to image: CIImage) -> CIImage {
        let filter = CIFilter.blendWithMask()
        
        filter.inputImage = image
        filter.maskImage = mask
        filter.backgroundImage = CIImage.empty()
        
        return filter.outputImage ?? image
    }
    
    // Convert CIImage to UIImage
    @available(iOS 17.0, *)
    private func convertToUIImage(ciImage: CIImage) -> UIImage {
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            fatalError("Failed to render CGImage")
        }
        
        return UIImage(cgImage: cgImage)
    }
}
