import pyodbc
import time
from datetime import datetime

# 数据库连接信息
server = '127.0.0.1,5433'
database = 'Statistics-CT-test'
username = 'sa'
password = '123456'

def connect_to_db():
    """连接到SQL Server数据库"""
    drivers = [
        'ODBC Driver 18 for SQL Server',
        'ODBC Driver 17 for SQL Server',
        'ODBC Driver 13 for SQL Server',
        'SQL Server Native Client 11.0',
        'SQL Server'
    ]

    for driver in drivers:
        try:
            conn_str = f'DRIVER={{{driver}}};SERVER={server};DATABASE={database};UID={username};PWD={password};TrustServerCertificate=yes'
            conn = pyodbc.connect(conn_str, timeout=300)
            print(f"[+] 成功连接到数据库: {database}")
            return conn
        except:
            continue

    print(f"[-] 数据库连接失败")
    return None

def get_procedure_definition(conn, proc_name):
    """获取存储过程定义"""
    cursor = conn.cursor()
    cursor.execute("SELECT OBJECT_DEFINITION(OBJECT_ID(?))", proc_name)
    result = cursor.fetchone()
    cursor.close()
    return result[0] if result else None

def test_procedure_performance(conn, proc_name, rounds=3):
    """测试存储过程性能"""
    print(f"\n测试存储过程: {proc_name}")
    print(f"测试轮次: {rounds}")
    print("-" * 60)

    results = []
    for i in range(1, rounds + 1):
        print(f"  轮次 {i}/{rounds}...", end='', flush=True)

        cursor = conn.cursor()
        cursor.execute("SET STATISTICS TIME ON")
        cursor.execute("SET STATISTICS IO ON")

        start = time.time()
        try:
            cursor.execute(f"EXEC {proc_name}")
            conn.commit()
            end = time.time()
            duration = (end - start) * 1000

            results.append({'success': True, 'duration_ms': duration})
            print(f" 完成 ({duration:.0f}ms)")
        except Exception as e:
            end = time.time()
            duration = (end - start) * 1000
            results.append({'success': False, 'duration_ms': duration, 'error': str(e)})
            print(f" 失败 - {str(e)[:50]}")

        cursor.execute("SET STATISTICS TIME OFF")
        cursor.execute("SET STATISTICS IO OFF")
        cursor.close()

        if i < rounds:
            time.sleep(1)

    successful = [r for r in results if r['success']]
    if successful:
        avg = sum(r['duration_ms'] for r in successful) / len(successful)
        print(f"\n  平均执行时间: {avg:.2f} ms")
        return avg
    return None

def main():
    print("=" * 80)
    print("存储过程性能分析 - usp_CheckProjectRiskWarn_Settlement")
    print("=" * 80)

    conn = connect_to_db()
    if not conn:
        return

    proc_name = 'dbo.usp_CheckProjectRiskWarn_Settlement'

    # 获取存储过程定义
    print("\n[1] 获取存储过程定义...")
    definition = get_procedure_definition(conn, proc_name)
    if definition:
        filename = 'usp_CheckProjectRiskWarn_Settlement_definition.sql'
        with open(filename, 'w', encoding='utf-8') as f:
            f.write(definition)
        print(f"[+] 已保存到: {filename} ({len(definition)} 字符)")
    else:
        print("[-] 未找到存储过程")
        conn.close()
        return

    # 测试性能
    print("\n[2] 测试原始性能...")
    avg_time = test_procedure_performance(conn, proc_name, 3)

    print("\n" + "=" * 80)
    print("分析完成！")
    print("=" * 80)

    conn.close()

if __name__ == "__main__":
    main()
