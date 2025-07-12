#ifndef STANDARDPLAYLIST_H
#define STANDARDPLAYLIST_H

#include "QObject"
#include "playlist.h"

class StandardPlayList : public PlayList
{
    Q_OBJECT
public:
    explicit StandardPlayList(const int id, const QString& name, QObject* parent = nullptr);

protected:
PlayList* createPlayList(int playListID, const QString& name) const override {
    return new StandardPlayList(playListID, name); 
}

};

#endif