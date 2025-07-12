#include "musicplayer.h"

#include <QTime>
// QSlider *miniPlayerProgress

MusicPlayer::MusicPlayer(QObject *parent)
    : QMediaPlayer(parent),
    audioOutput(new QAudioOutput(this)),
    miniPlayerProgress(nullptr),
    miniPlayerCurrentTime(nullptr),
    miniPlayerTotalTime(nullptr)
{
    lastLogTime = QTime::currentTime();

    // 将音频输出设备设置给播放器
    setAudioOutput(audioOutput);
    // 载入音乐
    connect(this, &QMediaPlayer::mediaStatusChanged, this, &MusicPlayer::onMediaStatusChanged);

    //音乐播放时，进度条变化
    connect(this, &QMediaPlayer::positionChanged, this, &MusicPlayer::updateProgressBar);

}

MusicPlayer::~MusicPlayer()
{
    delete audioOutput;
}

void MusicPlayer::setMiniPlayer(QSlider *progress, QTimeEdit *currentTime, QTimeEdit *totalTime)
{
    miniPlayerProgress = progress;
    miniPlayerCurrentTime = currentTime;
    miniPlayerTotalTime = totalTime;
}

void MusicPlayer::handleSliderReleased(){

    qDebug() << "Released to " <<  toProgressTime;

    QMediaPlayer::pause();
    QMediaPlayer::setPosition(toProgressTime);
    QMediaPlayer::play();

}

void MusicPlayer::handleSliderMoved(int value) {
    toProgressTime = static_cast<qint64>(value);
    qDebug() << "Moved to " << toProgressTime;
}


void MusicPlayer::handleSliderPressed() {

    if (!miniPlayerProgress->isSliderDown()){
        qDebug() << "Pressed";
    }

}

void MusicPlayer::setSource(const QUrl &url)
{
    QMediaPlayer::setSource(url);
}

void MusicPlayer::play()
{
    QMediaPlayer::play();
}

void MusicPlayer::pause()
{
    QMediaPlayer::pause();
}

void MusicPlayer::stop()
{
    QMediaPlayer::stop();
}

void MusicPlayer::setVolume(int volume)
{
    audioOutput->setVolume(qreal(volume) / 100.0); // 将音量范围从 0-100 转换为 0.0-1.0
}

void MusicPlayer::onMediaStatusChanged(QMediaPlayer::MediaStatus status)
{
    if (status == QMediaPlayer::LoadedMedia) {
        // 获取音乐文件时长
        qint64 durationMs = this->duration();
        qDebug() << "Media loaded. Duration (ms):" << durationMs;

        if (miniPlayerProgress) {
            miniPlayerProgress->setMaximum(static_cast<int>(durationMs / 1000));
            MusicPlayer::initProgressBar(durationMs, 0);
        }
    } else if (status == QMediaPlayer::InvalidMedia) {
        qDebug() << "Failed to load media.";
    }


    // 连接滑块拖动进度条信号
    connect(miniPlayerProgress, &QSlider::sliderPressed, this, &MusicPlayer::handleSliderPressed);
    connect(miniPlayerProgress, &QSlider::sliderMoved, this, &MusicPlayer::handleSliderMoved);
    connect(miniPlayerProgress, &QSlider::sliderReleased, this, &MusicPlayer::handleSliderReleased);

}

QTime MusicPlayer::getTimeObj(qint64 time){
    int hours = time / 3600000;
    int minutes = (time / 60000) % 60;
    int seconds = (time / 1000) % 60;

    QTime timeObj(hours, minutes, seconds);

    return timeObj;
}

QTime MusicPlayer::getTimeObj(int seconds) {
    int hours = seconds / 3600;
    int minutes = (seconds / 60) % 60;
    seconds = seconds % 60;

    QTime timeObj(hours, minutes, seconds);
    return timeObj;
}

// 初始化进度条
void MusicPlayer::initProgressBar(qint64 maximumTime, qint64 minimumTime) {
    // qint64 currentTime = minimumTime;
    int currentTime = static_cast<int>(minimumTime / 1000);
    // 计算当前时间和总时间的小时、分钟、秒
    int currentHours = currentTime / 3600000;
    // int currentMinutes = (currentTime / 60000) % 60;
    // int currentSeconds = (currentTime / 1000) % 60;

    int totalHours = maximumTime / 3600000;
    // int totalMinutes = (maximumTime / 60000) % 60;
    // int totalSeconds = (maximumTime / 1000) % 60;

    // 创建 QTime 对象
    QTime currentTimeObj = MusicPlayer::getTimeObj(currentTime);
    QTime totalTimeObj = MusicPlayer::getTimeObj(maximumTime);
    // QTime totalTimeObj(totalHours, totalMinutes, totalSeconds);

    // 动态设置时间显示格式
    if (currentHours > 0) {
        // 如果总时间超过1小时，使用 h:mm:ss 格式
        miniPlayerCurrentTime->setDisplayFormat("h:mm:ss");
    } else {
        // 否则使用 mm:ss 格式
        miniPlayerCurrentTime->setDisplayFormat("mm:ss");
    }

    if (totalHours > 0) {
        // 如果总时间超过1小时，使用 h:mm:ss 格式
        miniPlayerTotalTime->setDisplayFormat("h:mm:ss");
    } else {
        // 否则使用 mm:ss 格式
        miniPlayerTotalTime->setDisplayFormat("mm:ss");
    }

    // 更新 QTimeEdit 的时间
    miniPlayerCurrentTime->setTime(currentTimeObj);
    miniPlayerTotalTime->setTime(totalTimeObj);

    // 初始化进度条的值和范围
    if (miniPlayerProgress) {
        miniPlayerProgress->setMinimum(minimumTime);
        miniPlayerProgress->setMaximum(maximumTime);
        miniPlayerProgress->setValue(currentTime);
    }
}

void MusicPlayer::updateProgressBar(qint64 position) {
    // qDebug() << "Now:" << position;
    QTime currentTime = QTime::currentTime();
    if (lastLogTime.msecsTo(currentTime) >= 5000) {
        qDebug() << "Current position (every 5s):" << position;
        lastLogTime = currentTime; // 更新上一次日志输出的时间
    }
    if (!miniPlayerProgress->isSliderDown()) {
        if (miniPlayerProgress) {
            miniPlayerProgress->setValue(position);
        }

        if (miniPlayerCurrentTime) {
            QTime time = MusicPlayer::getTimeObj(position);
            miniPlayerCurrentTime->setTime(time);
        }
    }
}
