package com.ledgerlo.app

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
	private val channelNames = listOf(
		"com.ledgerlo.app/file_ops",
		"com.ledgerlo.app/files_ops",
	)

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		channelNames.forEach { channelName ->
			MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
				.setMethodCallHandler { call, result ->
					when (call.method) {
						"saveFileToDownloads" -> {
							val sourceFilePath = call.argument<String>("sourceFilePath")
							val fileName = call.argument<String>("fileName")
							val mimeType = call.argument<String>("mimeType")

							if (sourceFilePath.isNullOrBlank() || fileName.isNullOrBlank() || mimeType.isNullOrBlank()) {
								result.error(
									"INVALID_ARGS",
									"sourceFilePath, fileName and mimeType are required",
									null,
								)
								return@setMethodCallHandler
							}

							try {
								val uri = saveFileToDownloads(sourceFilePath, fileName, mimeType)
								result.success(uri)
							} catch (e: Exception) {
								result.error("SAVE_FAILED", e.message, null)
							}
						}

						"savePdfToDownloads" -> {
							val sourceFilePath = call.argument<String>("sourceFilePath")
							val fileName = call.argument<String>("fileName")

							if (sourceFilePath.isNullOrBlank() || fileName.isNullOrBlank()) {
								result.error(
									"INVALID_ARGS",
									"sourceFilePath and fileName are required",
									null,
								)
								return@setMethodCallHandler
							}

							try {
								val uri = savePdfToDownloads(sourceFilePath, fileName)
								result.success(uri)
							} catch (e: Exception) {
								result.error("SAVE_FAILED", e.message, null)
							}
						}

						else -> result.notImplemented()
					}
				}
		}
	}

	private fun savePdfToDownloads(sourceFilePath: String, fileName: String): String {
		return saveFileToDownloads(sourceFilePath, fileName, "application/pdf")
	}

	private fun saveFileToDownloads(sourceFilePath: String, fileName: String, mimeType: String): String {
		val resolver = applicationContext.contentResolver
		val values = ContentValues().apply {
			put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
			put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
				put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
			}
		}

		val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
			MediaStore.Downloads.EXTERNAL_CONTENT_URI
		} else {
			MediaStore.Files.getContentUri("external")
		}

		val itemUri = resolver.insert(collection, values)
			?: throw IllegalStateException("Could not create file in Downloads")

		val inputFile = java.io.File(sourceFilePath)
		if (!inputFile.exists()) {
			throw IllegalStateException("Temporary source file not found")
		}

		inputFile.inputStream().use { input ->
			resolver.openOutputStream(itemUri)?.use { output ->
				input.copyTo(output)
				output.flush()
			} ?: throw IllegalStateException("Could not open output stream")
		}

		return itemUri.toString()
	}
}
