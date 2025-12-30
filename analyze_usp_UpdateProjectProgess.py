# -*- coding: utf-8 -*-
"""
存储过程性能分析脚本: usp_UpdateProjectProgess
连接数据库并获取存储过程定义和性能信息
"""

import pyodbc
import time

def get_connection():
    """建立数据库连接，尝试多个ODBC驱动"""
    server = '127.0.0.1,5433'
    database = 'Statistics-CT-test'
    username = 'sa'
    password = '123456'

    drivers = [
        'ODBC Driver 18 for SQL Server',
        'ODBC Driver 17 for SQL Server',
        'ODBC Driver 13 for SQL Server',
        'SQL Server Native Client 11.0',
        'SQL Server'
    ]

    for driver in drivers:
        try:
            conn_str = f'DRIVER={{{driver}}};SERVER={server};DATABASE={database};UID={username};PWD={password};TrustServerCertificate=yes;'
            conn = pyodbc.connect(conn_str)
            print(f"[+] 成功连接到数据库 (使用驱动: {driver})")
            return conn
        except Exception as e:
            continue

    raise Exception("无法连接到数据库，请检查ODBC驱动是否安装")

def get_sp_definition(conn, sp_name):
    """获取存储过程定义"""
    cursor = conn.cursor()

    query = """
    SELECT OBJECT_DEFINITION(OBJECT_ID(?))
    """

    cursor.execute(query, sp_name)
    result = cursor.fetchone()

    if result and result[0]:
        return result[0]
    else:
        return None

def test_sp_performance(conn, sp_name, rounds=3):
    """测试存储过程性能"""
    print(f"\n[*] 开始测试存储过程性能 (执行 {rounds} 轮)...")

    execution_times = []

    for i in range(rounds):
        cursor = conn.cursor()

        try:
            # 启用执行统计
            cursor.execute("SET STATISTICS TIME ON")
            cursor.execute("SET STATISTICS IO ON")

            # 记录开始时间
            start_time = time.time()

            # 执行存储过程
            cursor.execute(f"EXEC {sp_name}")

            # 等待执行完成
            while cursor.nextset():
                pass

            # 记录结束时间
            end_time = time.time()
            execution_time = (end_time - start_time) * 1000  # 转换为毫秒

            execution_times.append(execution_time)
            print(f"  第 {i+1} 轮: {execution_time:.0f} ms")

            cursor.execute("SET STATISTICS TIME OFF")
            cursor.execute("SET STATISTICS IO OFF")

            cursor.close()
            conn.commit()

        except Exception as e:
            print(f"  第 {i+1} 轮执行出错: {str(e)}")
            cursor.close()
            conn.rollback()

    if execution_times:
        avg_time = sum(execution_times) / len(execution_times)
        print(f"\n[+] 平均执行时间: {avg_time:.0f} ms ({avg_time/1000:.2f} 秒)")
        return avg_time
    else:
        print("\n[-] 所有测试均失败")
        return None

def main():
    """主函数"""
    sp_name = 'dbo.usp_UpdateProjectProgess'

    print("="*60)
    print(f"存储过程性能分析: {sp_name}")
    print("="*60)

    # 连接数据库
    conn = get_connection()

    # 获取存储过程定义
    print(f"\n[*] 获取存储过程定义...")
    sp_definition = get_sp_definition(conn, sp_name)

    if sp_definition:
        print(f"[+] 成功获取存储过程定义 (长度: {len(sp_definition)} 字符)")

        # 保存到文件
        output_file = 'usp_UpdateProjectProgess_definition.sql'
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(sp_definition)
        print(f"[+] 已保存到文件: {output_file}")
    else:
        print(f"[-] 未找到存储过程: {sp_name}")
        conn.close()
        return

    # 测试性能
    avg_time = test_sp_performance(conn, sp_name)

    # 关闭连接
    conn.close()
    print("\n[+] 分析完成!")
    print("="*60)

if __name__ == "__main__":
    main()