// #include "playlistmanager.h"

// PlayListManager& PlayListManager::instance() {
//     static PlayListManager instance;
//     return instance;
// }

// PlayListManager::PlayListManager(QObject *parent)
//     : QObject{parent}, musicLib(MusicLibrary::instance())
// {
//     InitPlayList();
// }

// PlayListManager::~PlayListManager()
// {
// }

// void PlayListManager::InitPlayList(){
//     // 加载所有播放列表，但不包括歌曲信息，只有歌曲ID
//     playListsInfo =  musicLib.getPlayLists();

//     // 加载全部歌曲列表



//     // 加载Temp歌曲列表


// }

// int PlayListManager::PlayListExist(const QString &name, const int &playListID){

//     if (name.isEmpty() || playListID == -1 ){
//         return false;
//     }
//     bool foundByName = false;
//     bool foundById = false;
//     int matchedId = -1;
//     QString matchedName;

//     // 遍历播放列表容器
//     for (const PlayListInfo& playListInfo : playListsInfo) {
//         // Case 1：同时提供了有效name和playListID
//         if (!name.isEmpty() && playListID != -1) {
//             if (playListInfo->playListName == name && playListInfo->playListID == playListID) {
//                 // 精确匹配时直接返回ID
//                 return playListID;
//             }
//             // 记录名称或ID单独匹配的情况
//             if (playListInfo->playListName == name) foundByName = true;
//             if (playListInfo->playListID == playListID) foundById = true;
//         }
//         // Case 2：仅提供有效name
//         else if (!name.isEmpty()) {
//             if (playListInfo->playListName == name) {
//                 // 当发现重复名称时立即返回冲突
//                 if (matchedId != -1 && matchedId != playListInfo->playListID) {
//                     return -1;
//                 }
//                 matchedId = playListInfo->playListID;
//                 matchedName = name;
//             }
//         }
//         // Case 3：仅提供有效playListID
//         else if (playListID != -1) {
//             if (playListInfo->playListID == playListID) {
//                 return playListID;
//             }
//         }
//     }

//     // 处理最终结果
//     if (!name.isEmpty() && playListID != -1) {
//         // 同时提供两个参数但未精确匹配的情况
//         return (foundByName || foundById) ? -2 : -1; // -2表示存在部分匹配冲突
//     } 
//     else if (!name.isEmpty()) {
//         // 仅通过名称查找的结果
//         return matchedId;
//     }
    
//     // 默认返回未找到
//     return -1;
// }

// int PlayListManager::CreatePlayList(const QString &name){

//     QString playListName; 
//     QSharedPointer<PlayListInfo>;

//     playListName = name.isEmpty() ? "新播放列表" : name;
    
//     playListsInfo.append(QSharedPointer<PlayListInfo>::create(playListName));
//     return id;
// }

// int PlayListManager::DeletePlayList(const QString &name, const int &playListID){

//     int id = PlayListExist(name, playListID);

//     playListsInfo.removeIf([id](const PlayListInfo* info) {
//         return info->playListID == id;
//     });
//     return musicLib.deletePlayList(id);
// }

// QSharedPointer<PlayListInfo> PlayListManager::GetPlayList(const QString &name){

//     QString debugTitle = "GetPlayList";

//     QString playListName; 
//     playListName = name.isEmpty() ? "AllSongs" : name;

//     for (const auto& playlistInfo : playListsInfo) {
//         qDebug() << debugTitle << " - playListName: " << playlistInfo.playListName;
//         if (playlistInfo->playListName == playListName) {
//             return playlistInfo; 
//         }
//     }
// }