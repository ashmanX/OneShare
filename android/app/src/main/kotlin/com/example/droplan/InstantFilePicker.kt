package com.example.droplan

import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

class InstantFilePicker(private val activity: Activity) : PluginRegistry.ActivityResultListener {
    companion object {
        const val REQUEST_CODE_PICK = 9982
    }

    private var pendingResult: MethodChannel.Result? = null
    private val openPfds = HashMap<String, android.os.ParcelFileDescriptor>()

    fun closePfds() {
        for (pfd in openPfds.values) {
            try {
                pfd.close()
            } catch (_: Exception) {}
        }
        openPfds.clear()
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "pickFiles") {
            if (pendingResult != null) {
                result.error("ALREADY_PICKING", "File picker is already active", null)
                return
            }

            closePfds()
            pendingResult = result

            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }

            activity.startActivityForResult(intent, REQUEST_CODE_PICK)
        } else if (call.method == "clearPfds") {
            closePfds()
            result.success(null)
        } else {
            result.notImplemented()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE_PICK) {
            return false
        }

        val result = pendingResult
        pendingResult = null

        if (result == null) {
            return true
        }

        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Map<String, Any>>())
            return true
        }

        val filesList = mutableListOf<Map<String, Any>>()

        fun processUri(uri: Uri) {
            val name = getFileName(activity, uri) ?: "file"
            var size = getFileSize(activity, uri)
            var path = resolveBestPath(activity, uri, name)

            if (path != null) {
                if (size == 0L) {
                    try {
                        size = java.io.File(path).length()
                    } catch (_: Exception) {}
                }
                val map = HashMap<String, Any>()
                map["name"] = name
                map["size"] = size
                map["path"] = path
                filesList.add(map)
            }
        }

        if (data.clipData != null) {
            val count = data.clipData!!.itemCount
            for (i in 0 until count) {
                val item = data.clipData!!.getItemAt(i)
                if (item.uri != null) {
                    processUri(item.uri)
                }
            }
        } else if (data.data != null) {
            processUri(data.data!!)
        }

        result.success(filesList)
        return true
    }

    private fun resolveBestPath(context: Context, uri: Uri, fileName: String): String {
        // 1. Try real file path first
        val realPath = getRealPathFromURI(context, uri)
        if (realPath != null) {
            val f = java.io.File(realPath)
            if (f.exists() && f.canRead()) {
                return realPath
            }
        }

        // 2. Instant Content URI string (0ms delay for any file size)
        return uri.toString()
    }

    private fun clearCache(context: Context) {
        try {
            val cacheDir = java.io.File(context.cacheDir, "instant_picker_cache")
            if (cacheDir.exists()) {
                cacheDir.listFiles()?.forEach { file ->
                    if (file.isFile && System.currentTimeMillis() - file.lastModified() > 3600000) {
                        file.delete()
                    }
                }
            }
        } catch (_: Exception) {}
    }

    private fun copyUriToCache(context: Context, uri: Uri, fileName: String): String? {
        try {
            clearCache(context)
            val cacheDir = java.io.File(context.cacheDir, "instant_picker_cache")
            if (!cacheDir.exists()) {
                cacheDir.mkdirs()
            }
            val sanitizedName = fileName.replace("[\\\\/:*?\"<>|]".toRegex(), "_")
            val cacheFile = java.io.File(cacheDir, "${System.currentTimeMillis()}_$sanitizedName")
            context.contentResolver.openInputStream(uri)?.use { inputStream ->
                java.io.FileOutputStream(cacheFile).use { outputStream ->
                    inputStream.copyTo(outputStream)
                }
            }
            if (cacheFile.exists() && cacheFile.length() > 0) {
                return cacheFile.absolutePath
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return null
    }

    private fun getFileName(context: Context, uri: Uri): String? {
        if (uri.scheme == "content") {
            try {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (idx != -1) {
                            return cursor.getString(idx)
                        }
                    }
                }
            } catch (e: Exception) {
                // Ignore
            }
        }
        return uri.lastPathSegment
    }

    private fun getFileSize(context: Context, uri: Uri): Long {
        if (uri.scheme == "content") {
            try {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(OpenableColumns.SIZE)
                        if (idx != -1) {
                            return cursor.getLong(idx)
                        }
                    }
                }
            } catch (e: Exception) {
                // Ignore
            }
        }
        return 0L
    }

    private fun getRealPathFromURI(context: Context, uri: Uri): String? {
        if (DocumentsContract.isDocumentUri(context, uri)) {
            val docId = DocumentsContract.getDocumentId(uri)

            if ("com.android.externalstorage.documents" == uri.authority) {
                val split = docId.split(":")
                val type = split[0]
                if ("primary".equals(type, ignoreCase = true)) {
                    return "${Environment.getExternalStorageDirectory().absolutePath}/${split[1]}"
                } else {
                    return "/storage/$type/${split[1]}"
                }
            } else if ("com.android.providers.downloads.documents" == uri.authority) {
                if (docId.startsWith("raw:")) {
                    return docId.replaceFirst("raw:", "")
                }
                try {
                    val contentUri = ContentUris.withAppendedId(
                        Uri.parse("content://downloads/public_downloads"),
                        docId.toLong()
                    )
                    return getDataColumn(context, contentUri, null, null)
                } catch (e: Exception) {
                    // Ignore
                }
            } else if ("com.android.providers.media.documents" == uri.authority) {
                val split = docId.split(":")
                val type = split[0]
                val contentUri: Uri? = when (type) {
                    "image" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                    "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                    "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                    else -> MediaStore.Files.getContentUri("external")
                }
                val selection = "_id=?"
                val selectionArgs = arrayOf(split[1])
                return getDataColumn(context, contentUri, selection, selectionArgs)
            }
        } else if ("content".equals(uri.scheme, ignoreCase = true)) {
            return getDataColumn(context, uri, null, null)
        } else if ("file".equals(uri.scheme, ignoreCase = true)) {
            return uri.path
        }
        return null
    }

    private fun getDataColumn(context: Context, uri: Uri?, selection: String?, selectionArgs: Array<String>?): String? {
        if (uri == null) return null
        val column = "_data"
        val projection = arrayOf(column)
        try {
            context.contentResolver.query(uri, projection, selection, selectionArgs, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val columnIndex = cursor.getColumnIndex(column)
                    if (columnIndex != -1) {
                        return cursor.getString(columnIndex)
                    }
                }
            }
        } catch (e: Exception) {
            // Ignore
        }
        return null
    }
}
