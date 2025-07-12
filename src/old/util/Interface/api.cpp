#include "api.h"
#include "musiclibrary.h"

IPlayList* API::createPlayListDB() {
    return &MusicLibrary::instance(); 
}

ISong* API::createSongDB() {
    return &MusicLibrary::instance(); 
}

IAlbum* API::createAlbumDB() {
    return &MusicLibrary::instance(); 
}

ICache* API::createCacheDB() {
    return &MusicLibrary::instance(); 
}

ICharacter* API::createCharacterDB() {
    return &MusicLibrary::instance(); 
}

// IGenre* API::createGenreDB() {
//     return &MusicLibrary::instance(); 
// }

// ILang* API::createLangDB() {
//     return &MusicLibrary::instance(); 
// }