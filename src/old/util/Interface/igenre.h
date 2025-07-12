#pragma once
#include <QVector>
#include "musicdatastruct.h"

class IGenre{
public:
    virtual ~IGenre() = default;
    
    // 本地
    // 从本地歌曲中获取流派信息
    virtual QStringList readLocal(const QString &path) = 0;


    // 插入歌曲和流派的关系
    virtual bool pairSongGenre(const int &songID, const QString &genre) = 0;
    // 插入专辑和人物的关系
    virtual bool pairAlbumGenre(const int &AlbumID, const QString &genre) = 0;


    // 根据专辑id获取所有流派
    virtual QStringList searchGenrerbyAlbumID(const int &albumID) = 0;
    // 根据歌曲id获取所有流派
    virtual QStringList searchGenrebySongID(const int &songID) = 0;
    // 根据流派查询人物id
    virtual QVector<int> searchCharacterbyGenre(const QString &genre) = 0;
    // 根据流派查询所有歌曲
    virtual QVector<QSharedPointer<SongInfo>> searchSongbyGenre(const QString &genre) = 0;
    // 根据流派查询所有专辑
    virtual QVector<QSharedPointer<AlbumInfo>> searchAlbumbyGenre(const QString &genre) = 0;
};