// #ifndef PLAYLISTMANAGER_H
// #define PLAYLISTMANAGER_H

// #include <QObject>

// #include "app/util/Config/configmanager.h"
// #include "app/util/Config/musiclibrary.h"
// #include "standardplaylist.h"
// #include "smartplaylist.h"


// // 0号PlayList为所有歌曲：AllSongs
// // 1号PlayList为临时播放列表：TempSongs
// class PlayListManager : public QObject
// {
//     Q_OBJECT
 
// public:
//     static PlayListManager& instance();
//     ~PlayListManager();
//     // const MusicLibrary::PlayListInfo* allSongPlayListInfo;
//     // const MusicLibrary::PlayListInfo* tempSongPlayListInfo;
//     // StandardPlayList allSongPlayList;
//     // StandardPlayList tempSongPlayList;

//     QSharedPointer<PlayListInfo> GetPlayList(const QString &name= "");

// private:
//     explicit PlayListManager(QObject *parent = nullptr);
//     // ConfigManager &configManager;
//     MusicLibrary &musicLib;

//     QVector<QSharedPointer<PlayListInfo>>  playListsInfo;

//     void InitPlayList();
    
//     int PlayListExist(const QString &name = "",const  int &playListID = -1);

//     // void LoadPlayList(QString &name="", int &playListID = -1);
//     // 根据名字创建新播放列表，名字重复时返回错误
//     int CreatePlayList(const QString &name = "");
//     // Smart PlayList: key/pattern
//     // int CreateSmartPlayList(QString &name, QVector<QPair<QString, QString>> &keyPattern);
//     // 根据名字或id删除播放列表
//     int DeletePlayList(const QString &name= "", const int &playListID = -1);
//     // int DeleteSmartPlayList(QString &name="", int &playListID = -1);


// };

// #endif