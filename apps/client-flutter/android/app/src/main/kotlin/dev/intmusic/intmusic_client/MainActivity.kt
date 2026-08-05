package dev.intmusic.intmusic_client

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.media.AudioManager
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

object IntMusicPlatformBridge {
    var channel: MethodChannel? = null

    fun invoke(method: String, arguments: Any? = null) {
        channel?.invokeMethod(method, arguments)
    }
}

class MainActivity : FlutterActivity() {
    companion object {
        private const val PICK_LIBRARY_FOLDER_REQUEST = 41021
        private const val READ_LIBRARY_PERMISSION_REQUEST = 41022
        private const val SAVE_FILE_REQUEST = 41023
    }

    private var mediaServiceStarted = false
    private var pendingLibraryFolderResult: MethodChannel.Result? = null
    private var pendingFileSaveResult: MethodChannel.Result? = null
    private var pendingFileSaveSource: File? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val platformChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.intmusic/platform")
        IntMusicPlatformBridge.channel = platformChannel
        platformChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> {
                    result.success(
                        mapOf(
                            "systemTray" to false,
                            "mediaSession" to true,
                            "nativeBackdrop" to true,
                            "backgroundPlayback" to true,
                        ),
                    )
                }

                "updatePlayback" -> {
                    val arguments = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    val playbackState = arguments["state"]?.toString() ?: "stopped"
                    if (playbackState == "stopped" && !mediaServiceStarted) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    val intent =
                        Intent(this, IntMusicMediaService::class.java)
                            .setAction(IntMusicMediaService.ACTION_UPDATE)
                            .putExtra("state", playbackState)
                            .putExtra("title", arguments["title"]?.toString() ?: "IntMusic")
                            .putExtra("artist", arguments["artist"]?.toString() ?: "")
                            .putExtra("album", arguments["album"]?.toString() ?: "")
                            .putExtra("durationMs", (arguments["durationMs"] as? Number)?.toLong() ?: 0L)
                            .putExtra("positionMs", (arguments["positionMs"] as? Number)?.toLong() ?: 0L)
                    ContextCompat.startForegroundService(this, intent)
                    mediaServiceStarted = playbackState != "stopped"
                    result.success(null)
                }

                "getSystemVolume" -> result.success(systemVolumeState())
                "setSystemVolume" -> {
                    val arguments = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    setSystemVolume(arguments, result)
                }
                "selectClientLibraryFolder" -> selectClientLibraryFolder(result)
                "restoreClientLibraryFolder" -> restoreClientLibraryFolder(call.arguments, result)
                "saveFile" -> saveFile(call.arguments, result)
                "downloadDistributionTask" ->
                    downloadDistributionTask(call.arguments, result)
                "uploadDistributionSource" ->
                    uploadDistributionSource(call.arguments, result)
                "moveToBackground" -> {
                    moveTaskToBack(true)
                    result.success(null)
                }

                "showWindow" -> {
                    startActivity(
                        Intent(this, MainActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                    )
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        // Kept as a compatibility endpoint for older installed builds.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.intmusic/system")
            .setMethodCallHandler { call, result ->
                if (call.method == "moveToBackground") {
                    moveTaskToBack(true)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
        }
    }

    private fun systemVolumeState(): Map<String, Any> {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        val maximum = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val minimum =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                audioManager.getStreamMinVolume(AudioManager.STREAM_MUSIC)
            } else {
                0
            }
        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val fixed = audioManager.isVolumeFixed
        val range = (maximum - minimum).coerceAtLeast(1)
        return mapOf(
            "supported" to !fixed,
            "readable" to true,
            "writable" to !fixed,
            "volume" to ((current - minimum).toDouble() / range.toDouble()).coerceIn(0.0, 1.0),
            "muted" to
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    audioManager.isStreamMute(AudioManager.STREAM_MUSIC)
                } else {
                    current <= minimum
                },
            "steps" to range,
        )
    }

    private fun setSystemVolume(arguments: Map<*, *>, result: MethodChannel.Result) {
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
        if (audioManager.isVolumeFixed) {
            result.success(systemVolumeState())
            return
        }
        val maximum = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val minimum =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                audioManager.getStreamMinVolume(AudioManager.STREAM_MUSIC)
            } else {
                0
            }
        val requested = (arguments["volume"] as? Number)?.toDouble()?.coerceIn(0.0, 1.0) ?: 1.0
        val muted = arguments["muted"] == true
        val target =
            (minimum + requested * (maximum - minimum)).toInt().coerceIn(minimum, maximum)
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.adjustStreamVolume(
                AudioManager.STREAM_MUSIC,
                if (muted) AudioManager.ADJUST_MUTE else AudioManager.ADJUST_UNMUTE,
                0,
            )
        } else if (muted) {
            audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, minimum, 0)
        }
        result.success(systemVolumeState())
    }

    private fun selectClientLibraryFolder(result: MethodChannel.Result) {
        if (pendingLibraryFolderResult != null) {
            result.error(
                "folder_picker_busy",
                "Another music folder selection is already in progress",
                null,
            )
            return
        }
        pendingLibraryFolderResult = result
        val missingPermissions =
            libraryPermissions().filter {
                ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
            }
        if (missingPermissions.isNotEmpty()) {
            requestPermissions(
                missingPermissions.toTypedArray(),
                READ_LIBRARY_PERMISSION_REQUEST,
            )
            return
        }
        launchLibraryFolderPicker()
    }

    private fun launchLibraryFolderPicker() {
        val intent =
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                .addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
                )
        startActivityForResult(intent, PICK_LIBRARY_FOLDER_REQUEST)
    }

    private fun libraryPermissions(): List<String> =
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU ->
                listOf(Manifest.permission.READ_MEDIA_AUDIO)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ->
                listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
                listOf(
                    Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE,
                )
            else -> emptyList()
        }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != READ_LIBRARY_PERMISSION_REQUEST) {
            return
        }
        if (grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        ) {
            launchLibraryFolderPicker()
        } else {
            pendingLibraryFolderResult?.error(
                "music_permission_denied",
                "Music access is required to scan and play files from this folder",
                null,
            )
            pendingLibraryFolderResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            PICK_LIBRARY_FOLDER_REQUEST -> handleLibraryFolderResult(resultCode, data)
            SAVE_FILE_REQUEST -> handleFileSaveResult(resultCode, data)
        }
    }

    private fun handleLibraryFolderResult(resultCode: Int, data: Intent?) {
        val pending = pendingLibraryFolderResult ?: return
        pendingLibraryFolderResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pending.success(null)
            return
        }
        val uri = data.data!!
        try {
            val grantedFlags =
                data.flags and
                    (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(
                uri,
                grantedFlags and
                    (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION),
            )
            pending.success(libraryFolderPayload(uri))
        } catch (error: Exception) {
            pending.error(
                "folder_access_failed",
                "Unable to preserve access to the selected music folder",
                error.message,
            )
        }
    }

    private fun saveFile(arguments: Any?, result: MethodChannel.Result) {
        if (pendingFileSaveResult != null) {
            result.error(
                "file_save_busy",
                "Another file export is already in progress",
                null,
            )
            return
        }
        val values = arguments as? Map<*, *>
        val sourcePath = values?.get("sourcePath")?.toString()
        val suggestedName = values?.get("suggestedName")?.toString()
        val mimeType = values?.get("mimeType")?.toString()
        if (sourcePath.isNullOrBlank() || suggestedName.isNullOrBlank()) {
            result.error(
                "invalid_file_export",
                "The file export request is incomplete",
                null,
            )
            return
        }
        val source = File(sourcePath)
        if (!source.isFile || !source.canRead()) {
            result.error(
                "file_export_source_unavailable",
                "The file to export is unavailable",
                sourcePath,
            )
            return
        }
        pendingFileSaveResult = result
        pendingFileSaveSource = source
        val intent =
            Intent(Intent.ACTION_CREATE_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType(mimeType?.takeIf { it.isNotBlank() } ?: "application/octet-stream")
                .putExtra(Intent.EXTRA_TITLE, suggestedName)
        try {
            startActivityForResult(intent, SAVE_FILE_REQUEST)
        } catch (error: Exception) {
            pendingFileSaveResult = null
            pendingFileSaveSource = null
            result.error(
                "file_export_unavailable",
                "No system file provider can save the exported file",
                error.message,
            )
        }
    }

    private fun handleFileSaveResult(resultCode: Int, data: Intent?) {
        val pending = pendingFileSaveResult ?: return
        val source = pendingFileSaveSource
        pendingFileSaveResult = null
        pendingFileSaveSource = null
        val destination = data?.data
        if (resultCode != Activity.RESULT_OK || destination == null) {
            pending.success(false)
            return
        }
        if (source == null || !source.isFile) {
            pending.error(
                "file_export_source_unavailable",
                "The file to export is no longer available",
                null,
            )
            return
        }
        try {
            source.inputStream().use { input ->
                val output =
                    contentResolver.openOutputStream(destination, "wt")
                        ?: throw IllegalStateException(
                            "The selected destination cannot be opened for writing",
                        )
                output.use { input.copyTo(it) }
            }
            pending.success(true)
        } catch (error: Exception) {
            pending.error(
                "file_export_failed",
                "Unable to save the exported file",
                error.message,
            )
        }
    }

    private fun restoreClientLibraryFolder(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *>
        val bookmark = values?.get("bookmark")?.toString()
        if (bookmark.isNullOrBlank()) {
            result.error("invalid_folder_token", "Folder permission is missing", null)
            return
        }
        try {
            val uri = Uri.parse(bookmark)
            val hasPermission =
                contentResolver.persistedUriPermissions.any {
                    it.uri == uri && it.isReadPermission && it.isWritePermission
                }
            if (!hasPermission) {
                result.error(
                    "folder_access_expired",
                    "The selected folder permission is no longer valid",
                    bookmark,
                )
                return
            }
            result.success(libraryFolderPayload(uri))
        } catch (error: Exception) {
            result.error(
                "folder_restore_failed",
                "Unable to restore access to the selected music folder",
                error.message,
            )
        }
    }

    private fun downloadDistributionTask(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *>
        val apiUrl = values?.get("apiUrl")?.toString()
        val taskId = values?.get("taskId")?.toString()
        val bookmark = values?.get("bookmark")?.toString()
        val relativePath = values?.get("relativePath")?.toString()
        val expectedSize = (values?.get("expectedSize") as? Number)?.toLong()
        val expectedQuickHash = values?.get("expectedQuickHash")?.toString()
        if (apiUrl.isNullOrBlank() ||
            taskId.isNullOrBlank() ||
            bookmark.isNullOrBlank() ||
            relativePath.isNullOrBlank() ||
            expectedSize == null ||
            expectedSize < 0
        ) {
            result.error(
                "invalid_distribution",
                "The distribution download request is incomplete",
                null,
            )
            return
        }
        Thread {
            try {
                val treeUri = Uri.parse(bookmark)
                val hasPermission =
                    contentResolver.persistedUriPermissions.any {
                        it.uri == treeUri && it.isReadPermission && it.isWritePermission
                    }
                if (!hasPermission) {
                    throw SecurityException(
                        "The destination folder no longer has persistent read/write permission",
                    )
                }
                val downloadDirectory = File(cacheDir, "intmusic-distribution")
                downloadDirectory.mkdirs()
                val partial = File(downloadDirectory, "$taskId.part")
                downloadWithResume(apiUrl, partial, expectedSize)
                val quickHash = quickFileHash(partial)
                if (!expectedQuickHash.isNullOrBlank() &&
                    !quickHash.equals(expectedQuickHash, ignoreCase = true)
                ) {
                    throw IllegalStateException(
                        "Downloaded file failed its content verification",
                    )
                }
                copyIntoDocumentTree(treeUri, relativePath, taskId, partial)
                val bytes = partial.length()
                partial.delete()
                runOnUiThread {
                    result.success(
                        mapOf(
                            "bytes" to bytes,
                            "quickHash" to quickHash,
                        ),
                    )
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "distribution_download_failed",
                        "Unable to save the distributed music file",
                        error.message,
                    )
                }
            }
        }.start()
    }

    private fun uploadDistributionSource(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *>
        val apiUrl = values?.get("apiUrl")?.toString()
        val bookmark = values?.get("bookmark")?.toString()
        val relativePath = values?.get("relativePath")?.toString()
        val expectedSize = (values?.get("expectedSize") as? Number)?.toLong()
        if (apiUrl.isNullOrBlank() ||
            bookmark.isNullOrBlank() ||
            relativePath.isNullOrBlank() ||
            expectedSize == null ||
            expectedSize < 0
        ) {
            result.error(
                "invalid_source_upload",
                "The distribution source request is incomplete",
                null,
            )
            return
        }
        Thread {
            try {
                val treeUri = Uri.parse(bookmark)
                val hasPermission =
                    contentResolver.persistedUriPermissions.any {
                        it.uri == treeUri && it.isReadPermission
                    }
                if (!hasPermission) {
                    throw SecurityException(
                        "The source folder no longer has persistent read permission",
                    )
                }
                val source = documentForRelativePath(treeUri, relativePath)
                val connection = URL(apiUrl).openConnection() as HttpURLConnection
                connection.connectTimeout = 30_000
                connection.readTimeout = 60_000
                connection.requestMethod = "PUT"
                connection.doOutput = true
                connection.setFixedLengthStreamingMode(expectedSize)
                connection.setRequestProperty("Content-Type", "application/octet-stream")
                val uploaded =
                    try {
                        val bytes = connection.outputStream.use { output ->
                            contentResolver.openInputStream(source)?.use { input ->
                                input.copyTo(output, 128 * 1024)
                            } ?: throw IllegalStateException(
                                "Unable to open the selected source file",
                            )
                        }
                        if (bytes != expectedSize) {
                            throw IllegalStateException(
                                "The local source changed after its last library sync",
                            )
                        }
                        val responseCode = connection.responseCode
                        if (responseCode !in 200..299) {
                            val message =
                                connection.errorStream?.bufferedReader()?.use { it.readText() }
                                    ?: connection.responseMessage
                            throw IllegalStateException("HTTP $responseCode: $message")
                        }
                        bytes
                    } finally {
                        connection.disconnect()
                    }
                runOnUiThread {
                    result.success(mapOf("bytes" to uploaded))
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "distribution_source_upload_failed",
                        "Unable to upload the local source file",
                        error.message,
                    )
                }
            }
        }.start()
    }

    private fun downloadWithResume(url: String, partial: File, expectedSize: Long) {
        if (partial.exists() && partial.length() > expectedSize) {
            partial.delete()
        }
        while (partial.length() < expectedSize) {
            var offset = if (partial.exists()) partial.length() else 0L
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 30_000
            connection.readTimeout = 60_000
            connection.requestMethod = "GET"
            if (offset > 0) {
                connection.setRequestProperty("Range", "bytes=$offset-")
            }
            try {
                val responseCode = connection.responseCode
                if (offset > 0 && responseCode == HttpURLConnection.HTTP_OK) {
                    partial.delete()
                    offset = 0
                } else if (responseCode != HttpURLConnection.HTTP_OK &&
                    responseCode != HttpURLConnection.HTTP_PARTIAL
                ) {
                    val message =
                        connection.errorStream?.bufferedReader()?.use { it.readText() }
                            ?: connection.responseMessage
                    throw IllegalStateException("HTTP $responseCode: $message")
                }
                if (offset == 0L && partial.exists()) {
                    partial.delete()
                }
                FileOutputStream(partial, offset > 0).use { output ->
                    connection.inputStream.use { input ->
                        input.copyTo(output, 128 * 1024)
                    }
                    output.fd.sync()
                }
            } finally {
                connection.disconnect()
            }
            if (partial.length() < expectedSize) {
                throw IllegalStateException(
                    "Distribution source ended before the expected file size",
                )
            }
        }
        if (partial.length() != expectedSize) {
            throw IllegalStateException(
                "Downloaded size ${partial.length()} does not match expected size $expectedSize",
            )
        }
    }

    private fun quickFileHash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val size = file.length()
        val sampleSize = 64 * 1024
        RandomAccessFile(file, "r").use { input ->
            val firstSize = minOf(sampleSize.toLong(), size).toInt()
            val first = ByteArray(firstSize)
            input.readFully(first)
            digest.update(first)
            if (size > sampleSize.toLong()) {
                input.seek(maxOf(0L, size - sampleSize))
                val last = ByteArray(minOf(sampleSize.toLong(), size).toInt())
                input.readFully(last)
                digest.update(last)
            }
        }
        for (index in 0 until 8) {
            digest.update((size ushr (index * 8)).toByte())
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
    }

    private fun copyIntoDocumentTree(
        treeUri: Uri,
        relativePath: String,
        taskId: String,
        source: File,
    ) {
        val segments =
            relativePath
                .replace('\\', '/')
                .split('/')
                .filter { it.isNotBlank() }
        if (segments.isEmpty() ||
            segments.any {
                it == "." || it == ".." || it.contains('\u0000') || it.contains('/') || it.contains('\\')
            }
        ) {
            throw IllegalArgumentException("Core returned an unsafe destination path")
        }
        var parent =
            DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri),
            )
        for (directoryName in segments.dropLast(1)) {
            val existing = findDocumentChild(treeUri, parent, directoryName)
            parent =
                if (existing != null) {
                    if (existing.second != DocumentsContract.Document.MIME_TYPE_DIR) {
                        throw IllegalStateException(
                            "$directoryName exists but is not a folder",
                        )
                    }
                    existing.first
                } else {
                    DocumentsContract.createDocument(
                        contentResolver,
                        parent,
                        DocumentsContract.Document.MIME_TYPE_DIR,
                        directoryName,
                    ) ?: throw IllegalStateException("Unable to create folder $directoryName")
                }
        }

        val finalName = segments.last()
        val temporaryName = ".intmusic-$taskId.part"
        findDocumentChild(treeUri, parent, temporaryName)?.let {
            DocumentsContract.deleteDocument(contentResolver, it.first)
        }
        val temporary =
            DocumentsContract.createDocument(
                contentResolver,
                parent,
                "application/octet-stream",
                temporaryName,
            ) ?: throw IllegalStateException("Unable to create the temporary destination file")
        try {
            writeDocumentFile(temporary, source)
        } catch (error: Exception) {
            runCatching { DocumentsContract.deleteDocument(contentResolver, temporary) }
            throw error
        }

        findDocumentChild(treeUri, parent, finalName)?.let {
            DocumentsContract.deleteDocument(contentResolver, it.first)
        }
        val renameFailure =
            try {
                if (DocumentsContract.renameDocument(contentResolver, temporary, finalName) != null) {
                    return
                }
                "the storage provider returned no destination"
            } catch (error: Exception) {
                error.message ?: error.javaClass.simpleName
            }
        findDocumentChild(treeUri, parent, finalName)?.let { existing ->
            val size = documentSize(existing.first)
            if (size < 0 || size == source.length()) {
                return
            }
            DocumentsContract.deleteDocument(contentResolver, existing.first)
        }
        var destination: Uri? = null
        try {
            val created =
                DocumentsContract.createDocument(
                    contentResolver,
                    parent,
                    mimeTypeForFileName(finalName),
                    finalName,
                ) ?: throw IllegalStateException("Unable to create the destination file")
            destination = created
            writeDocumentFile(created, source)
            val size = documentSize(created)
            if (size >= 0 && size != source.length()) {
                throw IllegalStateException(
                    "Saved size $size does not match downloaded size ${source.length()}",
                )
            }
            findDocumentChild(treeUri, parent, temporaryName)?.let {
                DocumentsContract.deleteDocument(contentResolver, it.first)
            }
        } catch (error: Exception) {
            destination?.let {
                runCatching { DocumentsContract.deleteDocument(contentResolver, it) }
            }
            runCatching {
                findDocumentChild(treeUri, parent, temporaryName)?.let {
                    DocumentsContract.deleteDocument(contentResolver, it.first)
                }
            }
            throw IllegalStateException(
                "Unable to finalize $finalName: rename failed ($renameFailure); " +
                    "fallback copy failed (${error.message})",
                error,
            )
        }
    }

    private fun writeDocumentFile(destination: Uri, source: File) {
        contentResolver.openOutputStream(destination, "w")?.use { output ->
            source.inputStream().use { input -> input.copyTo(output, 128 * 1024) }
        } ?: throw IllegalStateException("Unable to open the destination file for writing")
    }

    private fun documentSize(uri: Uri): Long =
        contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: -1L

    private fun mimeTypeForFileName(fileName: String): String =
        MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(fileName.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"

    private fun findDocumentChild(
        treeUri: Uri,
        parentUri: Uri,
        displayName: String,
    ): Pair<Uri, String>? {
        val parentId = DocumentsContract.getDocumentId(parentUri)
        val childrenUri =
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
        val projection =
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            )
        contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            val idColumn =
                cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameColumn =
                cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val mimeColumn =
                cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_MIME_TYPE)
            while (cursor.moveToNext()) {
                if (cursor.getString(nameColumn) == displayName) {
                    return Pair(
                        DocumentsContract.buildDocumentUriUsingTree(
                            treeUri,
                            cursor.getString(idColumn),
                        ),
                        cursor.getString(mimeColumn),
                    )
                }
            }
        }
        return null
    }

    private fun documentForRelativePath(treeUri: Uri, relativePath: String): Uri {
        val segments =
            relativePath
                .replace('\\', '/')
                .split('/')
                .filter { it.isNotBlank() }
        if (segments.isEmpty() ||
            segments.any {
                it == "." || it == ".." || it.contains('\u0000') || it.contains('/') || it.contains('\\')
            }
        ) {
            throw IllegalArgumentException("Core returned an unsafe source path")
        }
        var current =
            DocumentsContract.buildDocumentUriUsingTree(
                treeUri,
                DocumentsContract.getTreeDocumentId(treeUri),
            )
        for ((index, segment) in segments.withIndex()) {
            val child =
                findDocumentChild(treeUri, current, segment)
                    ?: throw IllegalStateException("Source path is no longer available")
            if (index < segments.lastIndex &&
                child.second != DocumentsContract.Document.MIME_TYPE_DIR
            ) {
                throw IllegalStateException("$segment is not a folder")
            }
            current = child.first
        }
        return current
    }

    private fun libraryFolderPayload(uri: Uri): Map<String, String> {
        val path = rawPathForTree(uri)
        val displayName =
            File(path).name.takeIf { it.isNotBlank() }
                ?: DocumentsContract.getTreeDocumentId(uri).substringAfter(':', "Music")
        return mapOf(
            "path" to path,
            "bookmark" to uri.toString(),
            "displayName" to displayName,
        )
    }

    private fun rawPathForTree(uri: Uri): String {
        if (uri.authority != "com.android.externalstorage.documents") {
            throw UnsupportedOperationException(
                "Only folders from Android device storage are supported",
            )
        }
        val parts = DocumentsContract.getTreeDocumentId(uri).split(':', limit = 2)
        if (parts.size != 2) {
            throw UnsupportedOperationException("The selected folder path is not available")
        }
        val volume = parts[0]
        val relative = parts[1]
        val base =
            if (volume.equals("primary", ignoreCase = true)) {
                Environment.getExternalStorageDirectory()
            } else {
                File("/storage/$volume")
            }
        return if (relative.isBlank()) base.path else File(base, relative).path
    }

    override fun onDestroy() {
        pendingLibraryFolderResult?.error(
            "activity_destroyed",
            "Folder selection was interrupted",
            null,
        )
        pendingLibraryFolderResult = null
        IntMusicPlatformBridge.channel = null
        super.onDestroy()
    }
}
