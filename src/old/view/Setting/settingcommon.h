#ifndef SETTINGCOMMON_H
#define SETTINGCOMMON_H

#include <QWidget>
#include <QVBoxLayout>
#include <QGroupBox>
#include <QRadioButton>

#include "app/custom/CardCombo/cardcombo.h"
#include "app/custom/CardButton/cardbutton.h"
#include "app/custom/CardPathSelect/cardpathselect.h"

#include "app/view/MusicScanView/musicscanview.h"

#include "app/util/Config/configmanager.h"

class SettingCommon : public QWidget
{
    Q_OBJECT
public:
    explicit SettingCommon(QWidget *parent = nullptr);

private:

    QVBoxLayout *commonLayout;
    CardCombo *configStoragePathCard;
    CardCombo *libraryStoragePathCard;
    CardPathSelect *PathSelect;
    MusicScanView *musicScanView;
    ConfigManager &configManager;
    MusicScanner &musicScanner;

private slots:
    void ConfigStoragePathChanged(int index);
};

#endif // SETTINGCOMMON_H
