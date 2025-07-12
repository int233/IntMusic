#ifndef MUSICSERVICE_H
#define MUSICSERVICE_H

#include <QObject>

#include <QMediaPlayer>
#include <QAudioOutput>
#include <QSlider>
#include <QTimeEdit>
#include <QDebug>
#include <QUrl>

#include "app/util/Interface/iplaylist.h"
#include "app/util/Config/configmanager.h"
#include "app/util/Interface/musicdatastruct.h"
#include "app/util/Interface/api.h"

class MusicService : public QMediaPlayer
{
    Q_OBJECT
public:
    static MusicService &instance();
    ~MusicService();

    // 播放信息
    // 获取当前歌曲
    QSharedPointer<SongInfo> currentSongInfo() const;
    // 播放状态
    QMediaPlayer::PlaybackState playbackState() const;

    // 当前播放文件的路径
    // QString currentFilePath() const;

    // 当前音量（0-100）
    int currentVolume() const;

    // 播放进度（毫秒）
    qint64 positionMilliseconds() const;

    // 播放进度（秒）
    qint64 positionSeconds() const;

    // 播放进度百分比（0-100）
    int positionPercentage() const;

    // 当前播放文件的SongInfo
    // QSharedPointer<SongInfo> currentSongInfo() const;
    


    // 设置音乐文件的 URL
    // void setAudioSource(const QString &musicPath);
    // void setAudioSource(const QUrl &musicPath);

    // 播放音乐
    void play(); 
    // 暂停播放
    void pause();
    // 停止播放
    void stop(); 
    // 设置音量
    // void setVolume(int volume); 
    // 前进
    void playForward();
    //  后退
    void playBackward();
    


    // 设置文件
    // void setSong(QSharedPointer<SongInfo> songInfo);
    // void setSong(int &songID);
    // void setSong(QString &filePath);
private:
    explicit MusicService(QObject *parent = nullptr);
    MusicService(const MusicService&) = delete;
    MusicService& operator=(const MusicService&) = delete;

    ConfigManager &configManager;
    QAudioOutput *audioOutput;
    IPlayList *pl_db;
    QSharedPointer<PlayListInfo> playListInfo;
    // QVector<SongInfo> PreviousTwoSongsInfo(2);
    QSharedPointer<SongInfo> currentSong;
    // QVector<SongInfo> NextTwoSongsInfo(2);

    // 设置默认歌曲
    void setDefaultSong();

signals:
    void PreviousSong();
    void NextSong();
    void PlayPaused();
    void PlayStoped();
    void PlayResumed();
    void PlayStart();
    void VolumeChanged();
    void VolumeIncreased();
    void VolumeDecreased();

private slots:
    void onMediaStatusChanged(QMediaPlayer::MediaStatus status);

public slots:
    // 设置播放列表
    void setPlayList(QSharedPointer<PlayListInfo> playListInfotoSet);
    void setSong(const int songID);
    void setPos(qint64 pos);
    
};

#endif // MUSICSERVICE_H
