#include "miniplayer.h"
#include <QStyle>

MiniPlayer::MiniPlayer(QWidget *parent)
    : QWidget{parent}, player(&MusicService::instance())
{
    // MiniPlayer 布局
    QHBoxLayout *MiniPlayerLayout = new QHBoxLayout(this);
    QStyle *style = this->style();

    // MiniAlbum
    MiniAlbum = new QWidget();
    QHBoxLayout *MiniAlbumLayout = new QHBoxLayout(MiniAlbum);
    AlbumImage = new QGraphicsView(MiniAlbum);
    MusicTitles = new QWidget();
    QVBoxLayout *MusicTitlesLayout = new QVBoxLayout(MusicTitles);
    PlayingMusicTitle = new QLabel("TextLabel", MusicTitles);
    PlayingAblumTitle = new QLabel("TextLabel", MusicTitles);
    MusicTitlesLayout->addWidget(PlayingMusicTitle);
    MusicTitlesLayout->addWidget(PlayingAblumTitle);
    MiniAlbumLayout->addWidget(AlbumImage);
    MiniAlbumLayout->addWidget(MusicTitles);
    MiniPlayerLayout->addWidget(MiniAlbum);

    // MiniSlider
    MiniSlider = new QWidget();
    QHBoxLayout *MiniSliderLayout = new QHBoxLayout(MiniSlider);
    MiniPlayerCurrentTime = new QTimeEdit(MiniSlider);
    MiniPlayerCurrentTime->setButtonSymbols(QAbstractSpinBox::NoButtons);
    MiniPlayerProgress = new QSlider(Qt::Horizontal, MiniSlider);
    MiniPlayerTotalTime = new QTimeEdit(MiniSlider);
    MiniPlayerTotalTime->setButtonSymbols(QAbstractSpinBox::NoButtons);
    MiniSliderLayout->addWidget(MiniPlayerCurrentTime);
    MiniSliderLayout->addWidget(MiniPlayerProgress);
    MiniSliderLayout->addWidget(MiniPlayerTotalTime);
    MiniPlayerLayout->addWidget(MiniSlider);

    // MiniControler
    MiniControler = new QWidget();
    QHBoxLayout *MiniControlerLayout = new QHBoxLayout(MiniControler);
    MiniPlayerOrderMode = new QPushButton(MiniControler);
    MiniPlayerPrevious = new QPushButton(MiniControler);
    MiniPlayerPause = new QPushButton(MiniControler);
    MiniPlayerNext = new QPushButton(MiniControler);
    MiniPlayerSound = new QPushButton(MiniControler);

    MiniPlayerOrderMode->setIcon(style->standardIcon(QStyle::SP_BrowserStop));
    MiniPlayerPrevious->setIcon(style->standardIcon(QStyle::SP_MediaSkipBackward));
    MiniPlayerPause->setIcon(style->standardIcon(QStyle::SP_MediaPlay)); 
    MiniPlayerNext->setIcon(style->standardIcon(QStyle::SP_MediaSkipForward));
    MiniPlayerSound->setIcon(style->standardIcon(QStyle::SP_MediaVolume));


    MiniControlerLayout->addWidget(MiniPlayerOrderMode);
    MiniControlerLayout->addWidget(MiniPlayerPrevious);
    MiniControlerLayout->addWidget(MiniPlayerPause);
    MiniControlerLayout->addWidget(MiniPlayerNext);
    MiniControlerLayout->addWidget(MiniPlayerSound);
    MiniPlayerLayout->addWidget(MiniControler);

    // 连接信号槽
    connect(MiniPlayerPause, &QPushButton::clicked, this, &MiniPlayer::togglePlayPause);
    connect(MiniPlayerPrevious, &QPushButton::clicked, this, &MiniPlayer::togglePlayPrevious);
    connect(player, &QMediaPlayer::playbackStateChanged, this, &MiniPlayer::updatePlayPauseIcon);
    connect(player, &QMediaPlayer::durationChanged, this, &MiniPlayer::updateTotalTime);
    connect(player, &QMediaPlayer::durationChanged, this, &MiniPlayer::initProgressBar);
    connect(player, &QMediaPlayer::durationChanged, this, [this]{updateSongInfo();});
    connect(player, &QMediaPlayer::positionChanged, this, &MiniPlayer::updateProgressBar);
    connect(player, &QMediaPlayer::positionChanged, this, &MiniPlayer::updateCurrentTime);
    connect(MiniPlayerProgress, &QSlider::sliderMoved, this, &MiniPlayer::seekPosition);

}

void MiniPlayer::updatePlayPauseIcon(QMediaPlayer::PlaybackState state)
{
    if (state == QMediaPlayer::PlayingState) {
        MiniPlayerPause->setIcon(style()->standardIcon(QStyle::SP_MediaPause));
    } else {
        MiniPlayerPause->setIcon(style()->standardIcon(QStyle::SP_MediaPlay));
    }
}

void MiniPlayer::togglePlayPause(bool play) {
    if (player->playbackState() == QMediaPlayer::PlayingState && !play) {
        player->pause();
    } else if ((player->playbackState() == QMediaPlayer::StoppedState) && play){
        player->play();
    } else if ((player->playbackState() == QMediaPlayer::PausedState) && play) {
        player->play();
    } else {
        // 如果没有明确指定，则根据当前状态切换
        if (player->playbackState() == QMediaPlayer::PlayingState) {
            player->pause();
        } else {
            player->play();
        }
    }
}

void MiniPlayer::togglePlayPrevious(bool play) {

    player->playBackward();
}

void MiniPlayer::displaySongInfo(QSharedPointer<SongInfo>  songInfo){

    updateSongTitle(songInfo->title);

    updateAlbumTitle(songInfo->albumName);

    updateTotalTime(songInfo->durations);

}

void MiniPlayer::updateSongTitle(QString title){
    PlayingMusicTitle->setText(title);
}

void MiniPlayer::updateAlbumTitle(QString title){
    PlayingAblumTitle->setText(title);
}

void MiniPlayer::updateSongInfo(){
    QSharedPointer<SongInfo> songInfo = player->currentSongInfo();
    displaySongInfo(songInfo);
}

QTime MiniPlayer::getTimeObj(int seconds) {
    int hours = seconds / 3600;
    int minutes = (seconds / 60) % 60;
    seconds = seconds % 60;

    QTime timeObj(hours, minutes, seconds);
    return timeObj;
}

void MiniPlayer::updateTotalTime(qint64 durations){

    durations = durations/1000;

    if (durations > 0) {
        QTime duration(0, durations / 60, durations % 60);
        MiniPlayerTotalTime->setTime(duration);
        MiniPlayerTotalTime->setDisplayFormat("mm:ss");
    } else {
        MiniPlayerTotalTime->setTime(QTime(0, 0));
    }
}

void MiniPlayer::initProgressBar(qint64 durations){

    QString debugTitle = "initProgressBar";

    durations = durations/1000;

    MiniPlayerProgress->setMinimum(0);
    MiniPlayerProgress->setMaximum(durations);
    qDebug() << debugTitle << " - setMinimum: " << 0 << "; setMaximum: "<< durations;
}

void MiniPlayer::updateCurrentTime(qint64 durations){
    durations = durations/1000;
    if (durations > 0) {
        QTime duration(0, durations / 60, durations % 60);
        MiniPlayerCurrentTime->setTime(duration);
        MiniPlayerCurrentTime->setDisplayFormat("mm:ss");
    } else {
        MiniPlayerCurrentTime->setTime(QTime(0, 0));
    }
}

void MiniPlayer::updateProgressBar(qint64 position){

    position = position/1000;

    if (!MiniPlayerProgress->isSliderDown()) {
        if (MiniPlayerProgress) {
            MiniPlayerProgress->setValue(position);
        }

        if (MiniPlayerCurrentTime) {
            QTime time = MiniPlayer::getTimeObj(position);
            MiniPlayerCurrentTime->setTime(time);
        }
    }
}

void MiniPlayer::seekPosition(int position) {
    if (player) {
        qint64 posMs = static_cast<qint64>(position) * 1000;
        player->setPosition(posMs);
    }
}