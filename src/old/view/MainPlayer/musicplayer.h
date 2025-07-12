#ifndef MUSICPLAYER_H
#define MUSICPLAYER_H

#include <QObject>

#include <QMediaPlayer>
#include <QAudioOutput>
#include <QSlider>
#include <QTimeEdit>
#include <QDebug>


class MusicPlayer : public QMediaPlayer
{
    Q_OBJECT
public:
    explicit MusicPlayer(QObject *parent = nullptr);
    ~MusicPlayer();

    void setMiniPlayer(QSlider *miniPlayerProgress, QTimeEdit *miniPlayerCurrentTime, QTimeEdit *miniPlayerTotalTime);

    void setSource(const QUrl &url); // 设置音乐文件的 URL
    void play();                     // 播放音乐
    void pause();                    // 暂停播放
    void stop();                     // 停止播放
    void setVolume(int volume);      // 设置音量

    void initProgressBar(qint64 minimumTime, qint64 maximumTime);
    void updatePlayerUI();
    void onMediaStatusChanged(QMediaPlayer::MediaStatus status);

    QTime getTimeObj(qint64 time);
    QTime getTimeObj(int time);

private:
    QAudioOutput *audioOutput;
    QSlider *miniPlayerProgress;
    QTimeEdit *miniPlayerCurrentTime;
    QTimeEdit *miniPlayerTotalTime;
    QTime lastLogTime;
    qint64 toProgressTime;

signals:
    // void updateProgressBar(qint64 position);

private slots:
    void updateProgressBar(qint64 position);
    void handleSliderMoved(int value);
    void handleSliderReleased();
    void handleSliderPressed();

};

#endif // MUSICPLAYER_H
