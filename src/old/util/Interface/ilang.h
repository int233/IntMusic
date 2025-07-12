#pragma once
#include <QVector>
#include "musicdatastruct.h"

class ILang{
public:
    virtual ~ILang() = default;
    
    // 本地
    // 从本地歌曲中获取语言信息
    virtual QStringList readLocal(const QString &path) = 0;


    // 插入歌曲和语言的关系
    virtual bool pairSongLanguage(const int &songID, const QString &lan) = 0;
    // 插入专辑和人物的关系
    virtual bool pairAlbumLanguage(const int &AlbumID, const QString &lan) = 0;


    // 根据专辑id获取所有语言
    virtual QStringList searchLanbyAlbumID(const int &albumID) = 0;
    // 根据歌曲id获取所有语言
    virtual QStringList searchLanbySongID(const int &songID) = 0;
    // 根据语言查询人物id
    virtual QVector<int> searchCharacterbyLan(const QString &lan) = 0;
    // 根据语言查询所有歌曲
    virtual QVector<QSharedPointer<SongInfo>> searchSongbyLan(const QString &lan) = 0;
    // 根据语言查询所有专辑
    virtual QVector<QSharedPointer<AlbumInfo>> searchAlbumbyLan(const QString &lan) = 0;
};