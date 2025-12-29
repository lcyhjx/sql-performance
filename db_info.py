import pyodbc
import pandas as pd
from datetime import datetime

# 数据库连接配置
server = '127.0.0.1,5433'
database = 'master'  # 先连接到master数据库
username = 'sa'
password = '123456'  # 密码可以随便填写

try:
    # 尝试多个ODBC驱动
    drivers = [
        'ODBC Driver 18 for SQL Server',
        'ODBC Driver 17 for SQL Server',
        'SQL Server Native Client 11.0',
        'SQL Server'
    ]

    conn = None
    for driver in drivers:
        try:
            print(f"尝试使用驱动: {driver}")
            conn_str = f'DRIVER={{{driver}}};SERVER={server};DATABASE={database};UID={username};PWD={password};TrustServerCertificate=yes'
            conn = pyodbc.connect(conn_str, timeout=10)
            print(f"成功连接,使用驱动: {driver}")
            break
        except pyodbc.Error as e:
            continue

    if conn is None:
        raise Exception("无法找到可用的ODBC驱动")
    cursor = conn.cursor()

    print("=" * 80)
    print("数据库连接成功!")
    print("=" * 80)
    print()

    # 1. 获取所有数据库列表
    print("【1. 数据库列表】")
    print("-" * 80)
    cursor.execute("""
        SELECT
            name AS 数据库名称,
            database_id AS 数据库ID,
            create_date AS 创建日期,
            compatibility_level AS 兼容级别,
            state_desc AS 状态,
            recovery_model_desc AS 恢复模式,
            collation_name AS 排序规则
        FROM sys.databases
        ORDER BY name
    """)

    databases = cursor.fetchall()
    for db in databases:
        print(f"  数据库: {db[0]}")
        print(f"    - ID: {db[1]}")
        print(f"    - 创建日期: {db[2]}")
        print(f"    - 兼容级别: {db[3]}")
        print(f"    - 状态: {db[4]}")
        print(f"    - 恢复模式: {db[5]}")
        print(f"    - 排序规则: {db[6]}")
        print()

    # 2. 获取SQL Server版本信息
    print("【2. SQL Server 版本信息】")
    print("-" * 80)
    cursor.execute("SELECT @@VERSION AS 版本信息")
    version = cursor.fetchone()
    print(version[0])
    print()

    # 3. 获取服务器属性
    print("【3. 服务器基本信息】")
    print("-" * 80)
    cursor.execute("SELECT SERVERPROPERTY('ProductVersion') AS 产品版本")
    prod_version = cursor.fetchone()
    print(f"  产品版本: {prod_version[0]}")

    cursor.execute("SELECT SERVERPROPERTY('ProductLevel') AS 产品级别")
    prod_level = cursor.fetchone()
    print(f"  产品级别: {prod_level[0]}")

    cursor.execute("SELECT SERVERPROPERTY('Edition') AS 版本")
    edition = cursor.fetchone()
    print(f"  版本: {edition[0]}")

    cursor.execute("SELECT SERVERPROPERTY('ServerName') AS 服务器名称")
    server_name = cursor.fetchone()
    print(f"  服务器名称: {server_name[0]}")
    print()

    # 4. 获取数据库大小信息
    print("【4. 数据库大小统计】")
    print("-" * 80)
    cursor.execute("""
        SELECT
            DB_NAME(database_id) AS 数据库名称,
            CAST(SUM(size) * 8.0 / 1024 AS DECIMAL(10,2)) AS 大小MB
        FROM sys.master_files
        WHERE DB_NAME(database_id) IS NOT NULL
        GROUP BY database_id
        ORDER BY SUM(size) DESC
    """)

    sizes = cursor.fetchall()
    for size in sizes:
        print(f"  {size[0]}: {size[1]} MB")
    print()

    # 5. 获取当前连接信息
    print("【5. 当前连接信息】")
    print("-" * 80)
    cursor.execute("""
        SELECT
            session_id AS 会话ID,
            login_name AS 登录名,
            host_name AS 主机名,
            program_name AS 程序名,
            login_time AS 登录时间
        FROM sys.dm_exec_sessions
        WHERE session_id = @@SPID
    """)

    session = cursor.fetchone()
    print(f"  会话ID: {session[0]}")
    print(f"  登录名: {session[1]}")
    print(f"  主机名: {session[2]}")
    print(f"  程序名: {session[3]}")
    print(f"  登录时间: {session[4]}")
    print()

    # 6. 导出数据库列表到CSV
    print("【6. 导出数据库信息到文件】")
    print("-" * 80)
    cursor.execute("""
        SELECT
            name AS DatabaseName,
            database_id AS DatabaseID,
            create_date AS CreateDate,
            compatibility_level AS CompatibilityLevel,
            state_desc AS State,
            recovery_model_desc AS RecoveryModel,
            collation_name AS Collation
        FROM sys.databases
        ORDER BY name
    """)

    columns = [column[0] for column in cursor.description]
    data = cursor.fetchall()
    df = pd.DataFrame.from_records(data, columns=columns)

    output_file = 'd:/Lakin/project/sql-performance/database_info.csv'
    df.to_csv(output_file, index=False, encoding='utf-8-sig')
    print(f"  数据库信息已导出到: {output_file}")
    print()

    print("=" * 80)
    print("信息读取完成!")
    print("=" * 80)

    # 关闭连接
    cursor.close()
    conn.close()

except pyodbc.Error as e:
    print(f"数据库连接错误: {e}")
    print()
    print("请检查:")
    print("1. SSH隧道是否正常运行")
    print("2. 数据库连接信息是���正确")
    print("3. ODBC Driver 17 for SQL Server 是否已安装")
    print("   下载地址: https://go.microsoft.com/fwlink/?linkid=2223304")

except Exception as e:
    print(f"发生错误: {e}")
