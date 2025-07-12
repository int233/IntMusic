#include "musicservice.h"
#include "app/util/Interface/iplaylist.h"
#include "app/util/PlayList/standardplaylist.h"

MusicService& MusicService::instance() {
    static MusicService instance;
    return instance;
}

MusicService::MusicService(QObject *parent)
    : QMediaPlayer(parent),configManager(ConfigManager::instance()),audioOutput(new QAudioOutput(this)),pl_db(API::createPlayListDB())
{
    setAudioOutput(audioOutput);

    // 设置默认歌曲
    setDefaultSong();
    // 设置信号更新频率200ms
    // setNotifyInterval(200);

    // 实时更新播放进度
    // connect(this, &QMediaPlayer::positionChanged, this, &MusicService::)
}

MusicService::~MusicService()
{
    delete audioOutput;
}

void MusicService::setDefaultSong(){
    QString debugTitle = "MusicService - setDefaultSong";

    // 若temp列表没有歌曲，则设置默认为Allsong
    QSharedPointer<PlayListInfo> tempPlayListInfo = pl_db->loadPlayListbyID(1);
    if ((tempPlayListInfo->playlist->size())<1){
        qDebug() << debugTitle << " - Empty Playlist:  TempSongs, PlaylistID: 1";
        setPlayList(pl_db->loadPlayListbyID(0));
    } else {
        qDebug() << debugTitle << " - Playlist:  TempSongs, PlaylistID: 1, Song count: " << tempPlayListInfo->playlist->size();
        setPlayList(tempPlayListInfo);
    }

}

void MusicService::setPlayList(QSharedPointer<PlayListInfo> playListInfotoSet){

    QString debugTitle = "MusicService - setPlayList";

    qDebug() << debugTitle ;

    if (playListInfotoSet == nullptr){
        qDebug() << debugTitle << " - playListInfotoSet is NULL";
        return;
    }

    if (playListInfo == nullptr){
        qDebug() << debugTitle << " - playListInfo is NULL";
        playListInfo = playListInfotoSet;
        return;
    }
    
    if (playListInfotoSet->isEmpty){
        qDebug() << debugTitle << " - PlayList: " << playListInfotoSet->playListName << " is empty";
    } else {
        if (playListInfo->playListName == playListInfotoSet->playListName){
            qDebug() << debugTitle << " - PlayList: " << playListInfotoSet->playListName << " has already set";
        } else {
            qDebug() << debugTitle << " - PlayList: " << playListInfotoSet->playListName << " has set";
        }
    }

    playListInfo = playListInfotoSet;

}

void MusicService::setSong(const int songID){

    QString debugTitle = "MusicService - setSong";

    // 如果不存在，则切换至Temp列表，并新增
    if (!playListInfo->playlist->songExist(songID)){
        setPlayList(pl_db->loadPlayListbyID(1));
        playListInfo->playlist->addSong(songID);
        qDebug() << debugTitle << " - SongID: " << songID << "not found in PlayList: " << playListInfo->playListName;
    }
    // 如果存在于播放列表中，则正常设置

    currentSong = playListInfo->playlist->getSong(songID);
    // 加载PreviousTwoSongsInfo和NextTwoSongsInfo

    QMediaPlayer::setSource(QUrl(currentSong->filePath));
}

QMediaPlayer::PlaybackState MusicService::playbackState() const
{
    return QMediaPlayer::playbackState();
}

int MusicService::currentVolume() const
{
    return audioOutput->volume();
}

QSharedPointer<SongInfo> MusicService::currentSongInfo() const {return currentSong; }

qint64 MusicService::positionMilliseconds() const
{
    return position();
}

qint64 MusicService::positionSeconds() const
{
    return position() / 1000;
}

int MusicService::positionPercentage() const
{
    const qint64 dur = duration();
    return (dur > 0) ? static_cast<int>((position() * 100) / dur) : 0;
}

void MusicService::setPos(qint64 pos){
    QMediaPlayer::setPosition(pos);
}

void MusicService::play()
{
    QMediaPlayer::play();
}

void MusicService::playBackward(){

    QString debugTitle = "MusicService - playBackward";

    if (playListInfo == nullptr){
        qDebug() << debugTitle << " - playListInfo is NULL";
        return;
    }

    setSong(playListInfo->playlist->getPreviousSong(currentSong->songID)->songID);
    QMediaPlayer::play();
}

void MusicService::playForward()
{
    // QMediaPlayer::play();
}

void MusicService::pause()
{
    QMediaPlayer::pause();
}

void MusicService::stop()
{
    QMediaPlayer::stop();
}

void MusicService::onMediaStatusChanged(QMediaPlayer::MediaStatus status)
{
    if (status == QMediaPlayer::LoadedMedia) {
        qint64 durationMs = this->duration();
        qDebug() << "Media loaded. Duration (ms):" << durationMs;

    } else if (status == QMediaPlayer::InvalidMedia) {
        qDebug() << "Failed to load media.";
    }
}

