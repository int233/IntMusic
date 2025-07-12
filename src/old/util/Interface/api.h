#pragma once

#include "ialbum.h"
#include "icache.h"
#include "icharacter.h"
#include "igenre.h"
#include "ilang.h"
#include "iplaylist.h"
#include "isong.h"

class API {
public:
    static IPlayList* createPlayListDB();
    static ISong* createSongDB();
    static IAlbum* createAlbumDB();
    static ICache* createCacheDB();
    static ICharacter* createCharacterDB();
    // static IGenre* createGenreDB();
    // static ILang* createLangDB();
};

