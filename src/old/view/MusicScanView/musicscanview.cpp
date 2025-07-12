#include "musicscanview.h"

MusicScanView::MusicScanView(QWidget *parent)
    : QWidget(parent),configManager(ConfigManager::instance()),musicScanner(MusicScanner::instance())
{
    QVBoxLayout *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(5);

    CardButton *ScannerButton = new CardButton("扫描", "点击扫描音乐", this);

    layout->addWidget(ScannerButton);


    connect(ScannerButton->getPushButton(),
    &QPushButton::clicked,
    this,
    [this]{
        musicScanner.startScan();
    });
}


