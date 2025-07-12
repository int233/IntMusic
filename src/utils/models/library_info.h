#ifndef LIBRARY_INFO_H
#define LIBRARY_INFO_H

#include <QString>

struct LibraryInfo {
    qint8 m_index;      // 库的唯一标识符（如1, 2, 3）
    QString m_id;       // 库的唯一标识符（如"main_collection"）
    QString m_name;     // 库的显示名称
    QString m_path;     // 数据库文件路径
};


#endif // LIBRARY_INFO_H