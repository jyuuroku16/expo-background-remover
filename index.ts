import { requireNativeModule } from "expo-modules-core";

const BackgroundRemover = requireNativeModule("ExpoBackgroundRemover");

export type RemovalOptions = {
  trim?: boolean;
};

/**
 * Removes the background from an image.
 * Note: This method isn't usable on iOS simulators, you need to have a real device.
 * On iOS < 17.0, this will throw a 'REQUIRES_API_FALLBACK' error for you to handle with your API.
 * @param {string} imageURI The URI of the image to process.
 * @param {object} [options] An optional object with processing options.
 * @param {boolean} [options.trim] If true, trims transparent pixels from the output image. Defaults to true.
 * @returns The URI of the image with the background removed.
 * @returns the original URI if you are using an iOS simulator.
 * @throws Error with message 'REQUIRES_API_FALLBACK' if iOS < 17.0 (use API fallback).
 * @throws Error if the image could not be processed for an unknown reason.
 */
export async function removeBackground(
  imageURI: string,
  options: RemovalOptions = { trim: true }
): Promise<string> {
  try {
    const result: string = await BackgroundRemover.removeBackground(imageURI, options);
    return result;
  } catch (error) {
    if (
      error instanceof Error &&
      (error.message.includes("SimulatorError") || (error as any).code === "SimulatorError")
    ) {
      console.warn(
        "[ExpoBackgroundRemover]: You need to have a real device. This feature is not available on simulators. Returning the original image URI."
      );
      return imageURI;
    }

    throw error;
  }
}

/**
 * Check if native background removal is supported on this device.
 * @returns true if native ML is supported, false if API fallback is needed
 */
export async function isNativeBackgroundRemovalSupported(): Promise<boolean> {
  try {
    // Try with a dummy/test image to check capability
    await BackgroundRemover.removeBackground("test://capability-check", {});
    return true;
  } catch (error) {
    if (
      error instanceof Error &&
      (error.message.includes("REQUIRES_API_FALLBACK") ||
        (error as any).code === "REQUIRES_API_FALLBACK")
    ) {
      return false;
    }
    // For other errors (like invalid URL), assume native is supported
    return true;
  }
}
