#include "playlist.h"

#include <QSqlQuery>
#include <QSqlError>
#include <QSqlDatabase>

PlayList::PlayList(const int id, const QString& name, QObject* parent)
    : QObject{parent}, m_id(id), m_name(name), pl_db(API::createPlayListDB()), song_db(API::createSongDB())
{
    qDebug() << "PlayList - Initiating: " << m_name;
    m_lastModified = QDateTime::currentSecsSinceEpoch();
    loadFromLibrary();
    qDebug() << "PlayList - Initiated: " << m_name;
}

int PlayList::id() const { return m_id; }
QString PlayList::name() const { return m_name; }

void PlayList::setName(const QString& name) { 
    if(m_name != name) {
        m_name = name;
        emit PlayListChanged();
    }
}

QHash<int, QSharedPointer<SongInfo>>  PlayList::getSongs() const { return m_songs; }

QSharedPointer<SongInfo> PlayList::getFirstSong() const {return m_songs.value(m_songIDs.first()); }

QSharedPointer<SongInfo> PlayList::getSong(const int songID) const {return m_songs.value(songID); }

QSharedPointer<SongInfo> PlayList::getPreviousSong(int currentSongID) const {

    if (m_songIDs.isEmpty()) {
        return nullptr; // 空列表直接返回
    }

    // 查找当前歌曲的索引
    int currentIndex = m_songIDs.indexOf(currentSongID);
    if (currentIndex == -1) {
        return nullptr; // 当前歌曲不在列表中
    }

    // 计算前一个索引
    int previousIndex = currentIndex - 1;

    // 处理循环逻辑
    if (previousIndex < 0) {
        previousIndex = allowLoop ? m_songIDs.size() - 1 : -1; // 允许循环则跳转到末尾，否则标记无效
    }

    // 检查索引有效性
    if (previousIndex < 0 || previousIndex >= m_songIDs.size()) {
        return nullptr; // 非循环模式且已是第一首
    }

    // 获取上一首的 SongInfo
    int previousSongID = m_songIDs.at(previousIndex);
    return getSong(previousSongID);
}

QVector<int>  PlayList::getSongIDs() const { return m_songIDs; }

int PlayList::size() const { return m_songIDs.size(); }

bool PlayList::songExist(const int songID) const { return m_songIDs.contains(songID); }

int PlayList::addSong(const int songID) {
    QSharedPointer<SongInfo> songInfo = song_db->getSongInfobyID(songID);
    
    if (m_songs.contains(songInfo->songID)){
        qWarning() << "Duplicated song ID: " << songInfo->songID;
        emit InsertDuplicatedSong();
        return 0;
    }

    m_songs.insert(songInfo->songID, songInfo);
    m_songIDs.append(songInfo->songID);
    emit InsertSong();
    emit PlayListChanged();
}

int PlayList::removeSongs(const QVector<int> songIDs){

    // get valid songIDs
    QVector<int> validSongIDs;
    for (const int &songID : songIDs){
        if (m_songs.contains(songID)){
            validSongIDs.append(songID);
        }
    }

    // remove songs
    
    for (const int &songID : validSongIDs){
        m_songIDs.removeAll(songID);
        m_songs.remove(songID);
    }
    emit PlayListChanged();
    emit RemovedSong(songIDs);
    return 1;
}

int PlayList::moveSongs(const QVector<int> songIDs, const int songIDBeforeDes){

    // delete old songIDs
    for (const int &songID : songIDs){
        m_songIDs.removeAll(songID);
    }

    // Destination index
    int desIndex = songIDs.indexOf(songIDBeforeDes);
    for (auto it = songIDs.rbegin(); it != songIDs.rend(); ++it) {
        m_songIDs.insert(desIndex, *it); 
    }
    emit PlayListChanged();
}

int PlayList::saveToLibrary(){

    QString debugTitle = "saveToLibrary";

    pl_db->insertPlayList(m_name, m_songIDs);
}



void PlayList::loadFromLibrary(){

    QString debugTitle = "loadFromLibrary";

    m_songIDs.clear();
    m_songs.clear();

    qDebug() << debugTitle << " - loading PlayList: "  << m_id; 

    m_songIDs = pl_db->getSongIDbyPlayListID(m_id);
    
    for (const int &songID : m_songIDs){
        qDebug() << debugTitle << " - loading SongID: "  << songID; 
        // m_songIDs.append(songID);
        // qDebug() << debugTitle << " - loading: "  << songID; 
        m_songs.insert(songID, song_db->getSongInfobyID(songID));
        qDebug() << debugTitle << " - loaded: "  << songID << ", title: " << m_songs.value(songID)->title; 
    }

}



