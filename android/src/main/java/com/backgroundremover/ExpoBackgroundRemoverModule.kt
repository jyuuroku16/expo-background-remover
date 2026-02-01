package com.backgroundremover

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.Promise
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.subject.SubjectSegmentation
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenter
import com.google.mlkit.vision.segmentation.subject.SubjectSegmenterOptions
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class ExpoBackgroundRemoverModule : Module() {
  private var segmenter: SubjectSegmenter? = null
  private val worker = Executors.newSingleThreadExecutor()
  private val isProcessing = AtomicBoolean(false)
  private val MAX_ATTEMPTS = 3
  private val MAX_PIXELS = 4_000_000L

  override fun definition() = ModuleDefinition {
    Name("ExpoBackgroundRemover")

    AsyncFunction("removeBackground") { imageURI: String, options: Map<String, Any?>, promise: Promise ->
      removeBackground(imageURI, options, promise)
    }

    OnDestroy {
      try {
        segmenter?.close()
        worker.shutdownNow()
      } catch (_: Exception) {}
    }
  }

  private fun removeBackground(imageURI: String, options: Map<String, Any?>, promise: Promise) {
    if (!isProcessing.compareAndSet(false, true)) {
      promise.reject("BACKGROUND_REMOVER_BUSY", "Another background removal is in progress", null)
      return
    }
    
    val trim = options["trim"] as? Boolean ?: true
    
    worker.execute {
      try {
        val segmenter = this.segmenter ?: createSegmenter()
        processWithRetries(segmenter, imageURI, trim, promise, attempt = 1)
      } catch (t: Throwable) {
        if (isProcessing.compareAndSet(true, false)) {
          promise.reject("BACKGROUND_REMOVAL_ERROR", t.message ?: "Unknown error", t)
        }
      }
    }
  }

  private fun processWithRetries(segmenter: SubjectSegmenter, imageURI: String, trim: Boolean, promise: Promise, attempt: Int) {
    var image: Bitmap? = null
    try {
      image = getImageBitmap(imageURI)
      if (image == null) {
          throw Exception("Could not load image")
      }
      val inputImage = InputImage.fromBitmap(image, 0)
      segmenter.process(inputImage)
        .addOnFailureListener { e ->
          image.recycle()
          if (e is OutOfMemoryError || e.cause is OutOfMemoryError) {
            handleOOMRetry(segmenter, imageURI, trim, promise, attempt, e)
          } else {
            if (isProcessing.compareAndSet(true, false)) {
              promise.reject("PROCESSING_FAILED", e.message ?: "Processing failed", e)
            }
          }
        }
        .addOnSuccessListener { result ->
          try {
            val foregroundBitmap = result.foregroundBitmap
            if (foregroundBitmap != null) {
              val finalBitmap = if (trim) trimTransparentPixels(foregroundBitmap) else foregroundBitmap
              val path = URI(imageURI).path
              val fileName = path?.split("/")?.lastOrNull() ?: "result.png"
              val savedImageURI = saveImage(finalBitmap, fileName)
              if (isProcessing.compareAndSet(true, false)) {
                promise.resolve(savedImageURI)
              }
              if (finalBitmap !== foregroundBitmap) foregroundBitmap.recycle()
            } else {
              if (isProcessing.compareAndSet(true, false)) {
                promise.reject("NO_FOREGROUND", "No foreground detected", null)
              }
            }
          } catch (oom: OutOfMemoryError) {
            handleOOMRetry(segmenter, imageURI, trim, promise, attempt, oom)
          } catch (t: Throwable) {
            if (isProcessing.compareAndSet(true, false)) promise.reject(" processing_success_error", t.message, t)
          } finally {
            image?.recycle()
          }
        }
    } catch (oom: OutOfMemoryError) {
      image?.recycle()
      handleOOMRetry(segmenter, imageURI, trim, promise, attempt, oom)
    } catch (t: Throwable) {
      image?.recycle()
      if (isProcessing.compareAndSet(true, false)) promise.reject("load_error", t.message, t)
    }
  }

  private fun handleOOMRetry(segmenter: SubjectSegmenter, imageURI: String, trim: Boolean, promise: Promise, attempt: Int, err: Throwable) {
    if (attempt >= MAX_ATTEMPTS) {
      if (isProcessing.compareAndSet(true, false)) {
        promise.reject("OOM_ERROR", "Out of memory after $attempt attempts", err)
      }
      return
    }
    System.gc()
    processWithRetries(segmenter, imageURI, trim, promise, attempt + 1)
  }

  private fun createSegmenter(): SubjectSegmenter {
    val options = SubjectSegmenterOptions.Builder()
      .enableForegroundBitmap()
      .build()
    val segmenter = SubjectSegmentation.getClient(options)
    this.segmenter = segmenter
    return segmenter
  }

  private fun getImageBitmap(imageURI: String): Bitmap? {
    val context = appContext.reactContext ?: return null
    val uri = Uri.parse(imageURI)
    
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
      val source = ImageDecoder.createSource(context.contentResolver, uri)
      val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
        val outWidth = info.size.width
        val outHeight = info.size.height
        val total = outWidth.toLong() * outHeight.toLong()
        if (total > MAX_PIXELS) {
          val scale = Math.sqrt(total.toDouble() / MAX_PIXELS.toDouble())
          val targetWidth = (outWidth / scale).toInt().coerceAtLeast(1)
          val targetHeight = (outHeight / scale).toInt().coerceAtLeast(1)
          decoder.setTargetSize(targetWidth, targetHeight)
        }
        decoder.isMutableRequired = true
        decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
      }
      return bitmap.copy(Bitmap.Config.ARGB_8888, true)
    } else {
      val inputStream1 = context.contentResolver.openInputStream(uri)
      val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
      BitmapFactory.decodeStream(inputStream1, null, opts)
      inputStream1?.close()
      
      var inSampleSize = 1
      val rawW = opts.outWidth
      val rawH = opts.outHeight
      if (rawW > 0 && rawH > 0) {
        val total = rawW.toLong() * rawH.toLong()
        if (total > MAX_PIXELS) {
          val ratio = Math.sqrt(total.toDouble() / MAX_PIXELS.toDouble()).coerceAtLeast(1.0)
          while (true) {
            val next = inSampleSize * 2
            val scaledW = rawW / next
            val scaledH = rawH / next
            if (scaledW <= 0 || scaledH <= 0) break
            val scaledTotal = scaledW.toLong() * scaledH.toLong()
            if (scaledTotal < MAX_PIXELS || next > ratio) break
            inSampleSize = next
          }
        }
      }
      val opts2 = BitmapFactory.Options().apply {
        inJustDecodeBounds = false
        inPreferredConfig = Bitmap.Config.ARGB_8888
        inSampleSize = inSampleSize
      }
      val inputStream2 = context.contentResolver.openInputStream(uri)
      val decoded = BitmapFactory.decodeStream(inputStream2, null, opts2)
      inputStream2?.close()
      return decoded ?: MediaStore.Images.Media.getBitmap(context.contentResolver, uri)
    }
  }

  private fun trimTransparentPixels(bitmap: Bitmap): Bitmap {
    val totalPixels = bitmap.width * bitmap.height
    val coreCount = Runtime.getRuntime().availableProcessors()
    return if (totalPixels > 1000000 && coreCount >= 4) {
      trimTransparentPixelsParallel(bitmap)
    } else {
      trimTransparentPixelsSequential(bitmap)
    }
  }

  private fun trimTransparentPixelsSequential(bitmap: Bitmap): Bitmap {
    val width = bitmap.width
    val height = bitmap.height
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1

    for (y in 0 until height) {
      for (x in 0 until width) {
        val pixel = bitmap.getPixel(x, y)
        val alpha = (pixel shr 24) and 0xFF
        if (alpha > 0) {
          if (x < minX) minX = x
          if (x > maxX) maxX = x
          if (y < minY) minY = y
          if (y > maxY) maxY = y
        }
      }
    }

    if (maxX == -1 || maxY == -1) {
      return Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
    }

    val newWidth = maxX - minX + 1
    val newHeight = maxY - minY + 1
    return Bitmap.createBitmap(bitmap, minX, minY, newWidth, newHeight)
  }

  private fun trimTransparentPixelsParallel(bitmap: Bitmap): Bitmap {
    val width = bitmap.width
    val height = bitmap.height
    val coreCount = Runtime.getRuntime().availableProcessors()
    val threadCount = minOf(maxOf(coreCount, 4), 8)
    
    val quadrants = if (threadCount == 4) {
      val halfWidth = width / 2
      val halfHeight = height / 2
      listOf(
        Quadrant(0, 0, halfWidth, halfHeight),
        Quadrant(halfWidth, 0, width, halfHeight),
        Quadrant(0, halfHeight, halfWidth, height),
        Quadrant(halfWidth, halfHeight, width, height)
      )
    } else {
      val stripHeight = height / threadCount
      (0 until threadCount).map { i ->
        val startY = i * stripHeight
        val endY = if (i == threadCount - 1) height else (i + 1) * stripHeight
        Quadrant(0, startY, width, endY)
      }
    }

    val executor = Executors.newFixedThreadPool(threadCount)
    val futures = quadrants.map { quadrant ->
      executor.submit<QuadrantBounds> {
         findBoundsInQuadrant(bitmap, quadrant)
      }
    }

    val results = futures.map { it.get() }
    executor.shutdown()

    val globalBounds = mergeBounds(results)
    
    return if (globalBounds.isValid()) {
      Bitmap.createBitmap(bitmap, globalBounds.minX, globalBounds.minY, globalBounds.width(), globalBounds.height())
    } else {
      Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
    }
  }
  
  private data class Quadrant(val startX: Int, val startY: Int, val endX: Int, val endY: Int)
  
  private data class QuadrantBounds(val minX: Int, val minY: Int, val maxX: Int, val maxY: Int) {
    fun isValid() = maxX >= 0 && maxY >= 0
    fun width() = maxX - minX + 1
    fun height() = maxY - minY + 1
  }

  private fun findBoundsInQuadrant(bitmap: Bitmap, quadrant: Quadrant): QuadrantBounds {
    var minX = Int.MAX_VALUE
    var minY = Int.MAX_VALUE  
    var maxX = -1
    var maxY = -1
    
    for (y in quadrant.startY until quadrant.endY) {
      for (x in quadrant.startX until quadrant.endX) {
        val pixel = bitmap.getPixel(x, y)
        val alpha = (pixel shr 24) and 0xFF
        if (alpha > 0) {
          if (x < minX) minX = x
          if (x > maxX) maxX = x
          if (y < minY) minY = y  
          if (y > maxY) maxY = y
        }
      }
    }
    
    return QuadrantBounds(
      if (minX == Int.MAX_VALUE) -1 else minX,
      if (minY == Int.MAX_VALUE) -1 else minY,
      maxX,
      maxY
    )
  }

  private fun mergeBounds(results: List<QuadrantBounds>): QuadrantBounds {
    val validResults = results.filter { it.isValid() }
    if (validResults.isEmpty()) {
      return QuadrantBounds(-1, -1, -1, -1)
    }
    return QuadrantBounds(
      minX = validResults.minOf { it.minX },
      minY = validResults.minOf { it.minY }, 
      maxX = validResults.maxOf { it.maxX },
      maxY = validResults.maxOf { it.maxY }
    )
  }

  private fun saveImage(bitmap: Bitmap, fileName: String): String {
    val context = appContext.reactContext ?: throw Exception("Context not found")
    val pngFileName = fileName.substringBeforeLast('.') + ".png"
    val file = File(context.filesDir, pngFileName)
    val fileOutputStream = FileOutputStream(file)
    bitmap.compress(Bitmap.CompressFormat.PNG, 100, fileOutputStream)
    fileOutputStream.close()
    return file.toURI().toString()
  }
}
