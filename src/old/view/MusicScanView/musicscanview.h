#ifndef MUSICSCANVIEW_H
#define MUSICSCANVIEW_H

#include <QWidget>
#include <QListView>
#include <QStandardItemModel>
#include <QVBoxLayout>
#include <QLabel>
#include <QDebug>
#include <QMessageBox>

#include "app/util/MusicScan/musicscanner.h"
#include "app/util/Config/configmanager.h"

#include "app/custom/CardButton/cardbutton.h"

class MusicScanView : public QWidget {
    Q_OBJECT

public:
    explicit MusicScanView(QWidget *parent = nullptr);

private:
    MusicScanner &musicScanner;
    ConfigManager &configManager;
    CardButton *ScannerButton;
};

#endif // MUSICSCANVIEW_H
