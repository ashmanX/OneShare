package com.example.droplan

import android.content.Context
import android.net.Uri
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class UriStreamHandler(private val context: Context) {
    private val activeStreams = ConcurrentHashMap<String, InputStream>()

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openStream" -> {
                val uriString = call.argument<String>("uri")
                if (uriString == null) {
                    result.error("INVALID_ARG", "URI is required", null)
                    return
                }
                try {
                    val uri = Uri.parse(uriString)
                    val inputStream = context.contentResolver.openInputStream(uri)
                    if (inputStream == null) {
                        result.error("OPEN_FAILED", "Could not open InputStream for $uriString", null)
                        return
                    }
                    val streamId = UUID.randomUUID().toString()
                    activeStreams[streamId] = inputStream
                    result.success(streamId)
                } catch (e: Exception) {
                    result.error("OPEN_ERROR", e.message, null)
                }
            }
            "readChunk" -> {
                val streamId = call.argument<String>("streamId")
                val chunkSize = call.argument<Int>("chunkSize") ?: (64 * 1024)
                val inputStream = activeStreams[streamId]
                if (inputStream == null) {
                    result.success(null)
                    return
                }
                try {
                    val buffer = ByteArray(chunkSize)
                    val bytesRead = inputStream.read(buffer)
                    if (bytesRead <= 0) {
                        inputStream.close()
                        activeStreams.remove(streamId)
                        result.success(null)
                    } else if (bytesRead < chunkSize) {
                        result.success(buffer.copyOf(bytesRead))
                    } else {
                        result.success(buffer)
                    }
                } catch (e: Exception) {
                    try {
                        inputStream.close()
                    } catch (_: Exception) {}
                    activeStreams.remove(streamId)
                    result.error("READ_ERROR", e.message, null)
                }
            }
            "closeStream" -> {
                val streamId = call.argument<String>("streamId")
                if (streamId != null) {
                    val inputStream = activeStreams.remove(streamId)
                    try {
                        inputStream?.close()
                    } catch (_: Exception) {}
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun closeAllStreams() {
        for (stream in activeStreams.values) {
            try {
                stream.close()
            } catch (_: Exception) {}
        }
        activeStreams.clear()
    }
}
