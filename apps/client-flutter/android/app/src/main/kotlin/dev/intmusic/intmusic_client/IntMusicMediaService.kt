package dev.intmusic.intmusic_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle

class IntMusicMediaService : Service() {
    companion object {
        const val ACTION_UPDATE = "dev.intmusic.action.UPDATE"
        private const val ACTION_PLAY_PAUSE = "dev.intmusic.action.PLAY_PAUSE"
        private const val ACTION_PREVIOUS = "dev.intmusic.action.PREVIOUS"
        private const val ACTION_NEXT = "dev.intmusic.action.NEXT"
        private const val CHANNEL_ID = "intmusic_playback"
        private const val NOTIFICATION_ID = 49330
    }

    private lateinit var mediaSession: MediaSessionCompat
    private var playbackState = "stopped"
    private var title = "IntMusic"
    private var artist = ""
    private var album = ""
    private var durationMs = 0L
    private var positionMs = 0L

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        mediaSession = MediaSessionCompat(this, "IntMusic").apply {
            setFlags(
                MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
            setCallback(
                object : MediaSessionCompat.Callback() {
                    override fun onPlay() = IntMusicPlatformBridge.invoke("play")
                    override fun onPause() = IntMusicPlatformBridge.invoke("pause")
                    override fun onSkipToPrevious() = IntMusicPlatformBridge.invoke("previous")
                    override fun onSkipToNext() = IntMusicPlatformBridge.invoke("next")
                    override fun onStop() = IntMusicPlatformBridge.invoke("stop")

                    override fun onSeekTo(pos: Long) {
                        positionMs = pos.coerceAtLeast(0)
                        IntMusicPlatformBridge.invoke("seek", positionMs)
                    }
                },
            )
            isActive = true
        }
        publishState()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_UPDATE -> {
                playbackState = intent.getStringExtra("state") ?: "stopped"
                title = intent.getStringExtra("title") ?: "IntMusic"
                artist = intent.getStringExtra("artist") ?: ""
                album = intent.getStringExtra("album") ?: ""
                durationMs = intent.getLongExtra("durationMs", 0L)
                positionMs = intent.getLongExtra("positionMs", 0L)
                publishState()
            }

            ACTION_PLAY_PAUSE -> IntMusicPlatformBridge.invoke("togglePlayPause")
            ACTION_PREVIOUS -> IntMusicPlatformBridge.invoke("previous")
            ACTION_NEXT -> IntMusicPlatformBridge.invoke("next")
        }
        val manager = getSystemService(NotificationManager::class.java)
        if (playbackState == "stopped") {
            manager.cancel(NOTIFICATION_ID)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }
        manager.notify(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        mediaSession.isActive = false
        mediaSession.release()
        super.onDestroy()
    }

    private fun publishState() {
        val compatState =
            when (playbackState) {
                "playing" -> PlaybackStateCompat.STATE_PLAYING
                "paused" -> PlaybackStateCompat.STATE_PAUSED
                else -> PlaybackStateCompat.STATE_STOPPED
            }
        val speed = if (playbackState == "playing") 1f else 0f
        mediaSession.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or
                        PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_PLAY_PAUSE or
                        PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                        PlaybackStateCompat.ACTION_STOP or
                        PlaybackStateCompat.ACTION_SEEK_TO,
                )
                .setState(compatState, positionMs, speed)
                .build(),
        )
        mediaSession.setMetadata(
            MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
                .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, album)
                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, durationMs)
                .build(),
        )
    }

    private fun buildNotification(): Notification {
        val openApp =
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(listOf(artist, album).filter { it.isNotBlank() }.joinToString(" · "))
            .setContentIntent(openApp)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setOngoing(playbackState == "playing")
            .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
            .setStyle(
                MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2),
            )
            .addAction(
                android.R.drawable.ic_media_previous,
                "Previous",
                servicePendingIntent(ACTION_PREVIOUS, 1),
            )
            .addAction(
                if (playbackState == "playing") {
                    android.R.drawable.ic_media_pause
                } else {
                    android.R.drawable.ic_media_play
                },
                if (playbackState == "playing") "Pause" else "Play",
                servicePendingIntent(ACTION_PLAY_PAUSE, 2),
            )
            .addAction(
                android.R.drawable.ic_media_next,
                "Next",
                servicePendingIntent(ACTION_NEXT, 3),
            )
            .build()
    }

    private fun servicePendingIntent(action: String, requestCode: Int): PendingIntent {
        return PendingIntent.getService(
            this,
            requestCode,
            Intent(this, IntMusicMediaService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel =
            NotificationChannel(
                CHANNEL_ID,
                "Music playback",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Playback controls and current track"
                setShowBadge(false)
            }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }
}
