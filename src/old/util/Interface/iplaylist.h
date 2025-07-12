#pragma once
#include <QVector>
#include <QString>
#include "musicdatastruct.h"

struct PlayListInfo;

class IPlayList {
public:
    virtual ~IPlayList() = default;

    // 加载所有的播放列表
    
    // 向数据库中插入和更新播放列表
    virtual int insertPlayList(const QString &name, const QVector<int> songIDs = {}) = 0;
    // 删除数据库中的播放列表
    virtual bool deletePlayList(const int playListID) = 0;
    // 从数据库中载入播放列表
    virtual QSharedPointer<PlayListInfo> loadPlayListbyName(const QString &name)  = 0;
    virtual QSharedPointer<PlayListInfo> loadPlayListbyID(const int playListID)  = 0;
    // 从根据播放列表id，获取所有_songid
    virtual QVector<int> getSongIDbyPlayListID(const int playListID)  = 0;
};