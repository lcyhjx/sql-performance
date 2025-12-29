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
        'ODBC Driver 17 for SQL Server',
        'ODBC Driver 18 for SQL Server',
        'ODBC Driver 13 for SQL Server',
        'SQL Server Native Client 11.0',
        'SQL Server'
    ]

    for driver in drivers:
        try:
            conn_str = f'DRIVER={{{driver}}};SERVER={server};DATABASE={database};UID={username};PWD={password};TrustServerCertificate=yes'
            conn = pyodbc.connect(conn_str, timeout=300)
            print(f"[+] 成功连接到数据库: {database} (驱动: {driver})")
            return conn
        except Exception as e:
            continue

    print(f"[-] 数据库连接失败")
    return None

def get_stored_procedure_definition(conn, proc_name):
    """获取存储过程定义"""
    cursor = conn.cursor()
    query = """
    SELECT OBJECT_DEFINITION(OBJECT_ID(?)) AS definition
    """
    cursor.execute(query, proc_name)
    result = cursor.fetchone()
    cursor.close()
    return result[0] if result else None

def get_procedure_stats(conn, proc_name):
    """获取存储过程的统计信息"""
    cursor = conn.cursor()
    query = """
    SELECT
        d.object_id,
        OBJECT_NAME(d.object_id) AS procedure_name,
        d.cached_time,
        d.last_execution_time,
        d.execution_count,
        d.total_worker_time / 1000 AS total_cpu_ms,
        d.total_elapsed_time / 1000 AS total_elapsed_ms,
        d.total_logical_reads,
        d.total_logical_writes,
        CASE WHEN d.execution_count > 0
            THEN d.total_worker_time / d.execution_count / 1000
            ELSE 0
        END AS avg_cpu_ms,
        CASE WHEN d.execution_count > 0
            THEN d.total_elapsed_time / d.execution_count / 1000
            ELSE 0
        END AS avg_elapsed_ms,
        CASE WHEN d.execution_count > 0
            THEN d.total_logical_reads / d.execution_count
            ELSE 0
        END AS avg_logical_reads
    FROM sys.dm_exec_procedure_stats d
    WHERE OBJECT_NAME(d.object_id) = ?
    """
    cursor.execute(query, proc_name)
    result = cursor.fetchone()
    cursor.close()
    return result

def execute_procedure_with_timing(conn, proc_name, params=None):
    """执行存储过程并测量性能"""
    cursor = conn.cursor()

    # 启用统计信息
    cursor.execute("SET STATISTICS TIME ON")
    cursor.execute("SET STATISTICS IO ON")

    start_time = time.time()

    try:
        if params:
            cursor.execute(f"EXEC {proc_name} {params}")
        else:
            cursor.execute(f"EXEC {proc_name}")

        # 获取结果集(如果有)
        rows = []
        try:
            rows = cursor.fetchall()
        except:
            pass

        # 提交事务(如果有修改)
        conn.commit()

        end_time = time.time()
        execution_time = (end_time - start_time) * 1000

        return {
            'success': True,
            'execution_time_ms': execution_time,
            'row_count': len(rows)
        }
    except Exception as e:
        return {
            'success': False,
            'error': str(e)
        }
    finally:
        cursor.execute("SET STATISTICS TIME OFF")
        cursor.execute("SET STATISTICS IO OFF")
        cursor.close()

def main():
    print("=" * 80)
    print("存储过程性能分析工具")
    print("=" * 80)

    proc_name = 'dbo.usp_CheckProjectRiskWarn_Contract'

    # 连���数据库
    conn = connect_to_db()
    if not conn:
        return

    print(f"\n分析存储过程: {proc_name}")
    print("-" * 80)

    # 1. 获取存储过程定义
    print("\n[1] 获取存储过程定义...")
    definition = get_stored_procedure_definition(conn, proc_name)
    if definition:
        print(f"[+] 存储过程定义已获取 ({len(definition)} 字符)")

        # 保存定义到文件
        filename = 'usp_CheckProjectRiskWarn_Contract_definition.sql'
        with open(filename, 'w', encoding='utf-8') as f:
            f.write(definition)
        print(f"[+] 已保存到: {filename}")
    else:
        print("[-] 未找到存储过程")
        conn.close()
        return

    # 2. 获取历史统计信息
    print("\n[2] 获取历史执行统计...")
    stats = get_procedure_stats(conn, proc_name.split('.')[-1])
    if stats:
        print(f"  执行次数: {stats[4]}")
        print(f"  平均CPU时间: {stats[9]:.2f} ms")
        print(f"  平均执行时间: {stats[10]:.2f} ms")
        print(f"  平均逻辑读取: {stats[11]:.0f} 页")
    else:
        print("  无历史统计信息（可能尚未执行过）")

    # 3. 执行性能测试
    print("\n[3] 执行性能测试...")
    print("  测试轮次: 3")

    results = []
    for i in range(1, 4):
        print(f"  轮次 {i}/3...", end='', flush=True)
        result = execute_procedure_with_timing(conn, proc_name)
        results.append(result)

        if result['success']:
            print(f" 完成 ({result['execution_time_ms']:.0f}ms)")
        else:
            print(f" 失败")
            print(f"    错误: {result['error']}")

        # 等待1秒
        if i < 3:
            time.sleep(1)

    # 计算平均值
    successful = [r for r in results if r['success']]
    if successful:
        avg_time = sum(r['execution_time_ms'] for r in successful) / len(successful)
        print(f"\n  平均执行时间: {avg_time:.2f} ms")

    # 生成分析报告
    print("\n" + "=" * 80)
    print("分析完成！")
    print("=" * 80)
    print("\n下一步: 基于以上信息，分析性能瓶颈并创建优化方案")

    conn.close()

if __name__ == "__main__":
    main()
