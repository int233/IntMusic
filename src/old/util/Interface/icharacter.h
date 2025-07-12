#pragma once
#include <QVector>
#include "musicdatastruct.h"

struct CharacterInfo;
struct SongInfo;
struct AlbumInfo;

class ICharacter {
public:
    virtual ~ICharacter() = default;
    
    // 本地
    // 从本地歌曲中获取人物信息
    virtual QVector<QSharedPointer<CharacterInfo>> readLocalSongCharacter(const QString &path) = 0;

    // 插入人物
    virtual int insertCharacter(QSharedPointer<CharacterInfo>) = 0;
    // 检查人物是否存在
    virtual int characterExists(const QString& name, const QString& foreign, const int overlapID = 0) = 0;
    // 插入歌曲和人物的关系
    virtual bool pairSongCharacter(const int songID, const int characterID, const QString &role) = 0;
    // 插入专辑和人物的关系
    virtual bool pairAlbumCharacter(const int AlbumID, const int characterID, const QString &role) = 0;

    // 根据人物id获取人物信息
    virtual QSharedPointer<CharacterInfo> getCharacterInfobyID(const int characterID) = 0;
    // 根据专辑id获取所有人物
    virtual QVector<QSharedPointer<CharacterInfo>> searchCharacterbyAlbumID(const int albumID) = 0;
    // 根据歌曲id获取所有人物
    virtual QVector<QSharedPointer<CharacterInfo>> searchCharacterbySongID(const int songID) = 0;
    // 根据不同信息查询人物id
    // virtual QVector<int> searchCharacter(const QString &key, const QVariant &value) = 0;
    // 根据人物id查询所有歌曲
    virtual QVector<QSharedPointer<SongInfo>> searchSongbyCharacterID(const int characterID) = 0;
    // 根据人物id查询所有专辑
    virtual QVector<QSharedPointer<AlbumInfo>> searchAlbumbyCharacterID(const int characterID) = 0;
};