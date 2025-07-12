#ifndef SMARTPLAYLIST_H
#define SMARTPLAYLIST_H

#include "QObject"
#include "playlist.h"

class SmartPlayList : public PlayList
{
    Q_OBJECT
public:
    explicit SmartPlayList(const int id, const QString& name, QObject* parent = nullptr);
    bool isSmart() const override { return true; }

    // virtual void updateSmartRules(const QJsonObject& rules) = 0;
    // virtual void refreshSongs() = 0;


};

#endif