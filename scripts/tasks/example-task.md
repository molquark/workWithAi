<!--
  这是任务书模板。复制成 queue\<任务号>.md 就能用。

  写任务书是这套流程里唯一真正需要你动脑的环节，也是最决定成败的环节。
  经验法则：**如果一段话你自己读完还觉得"大概知道要干什么"，
  那就还不够具体，AI 一定会做成另一个东西。**

  必备的四块：背景 / 要做的事 / 验收标准 / 相关代码。
  最后那块「相关代码」看着像废话，实际最能省时间——一个 27B 模型在仓库里
  瞎找半小时，就为了找一个你没告诉它路径的类。
-->

# PROJ-1024 订单列表支持导出

## 背景

运营需要把订单列表导出成 Excel 做月度对账。现在只能一页页看，一天要花两小时。

## 要做的事

1. 新增接口 `GET /api/order/export`，请求参数和 `GET /api/order/list` **完全一致**
2. 返回 Excel 流，文件名 `订单导出_yyyyMMdd.xlsx`
3. **复用**现有的 `OrderQueryService` 查询逻辑，不要另写一套 SQL
4. 导出上限 10000 条，超了返回 `Result.fail("导出数据超过 10000 条，请缩小范围")`

## 验收标准

必须让这个命令通过：

    mvn -q -pl order-service -am test

并且新增测试 `OrderExportTest`，覆盖三个用例：

- 正常导出：3 条订单 → 文件能打开，行数 = 4（含表头）
- 超限：10001 条 → 返回 fail，不生成文件
- 空结果：0 条 → 文件只有表头

## 不要做的事

- 不要改 `pom.xml`（`easyexcel` 已经在依赖里了，直接用现成的）
- 不要动 `OrderQueryService` 现有方法的签名
- 不要"顺手"优化 list 接口

## 相关代码

- `order-service/src/main/java/com/example/order/controller/OrderController.java`
- `order-service/src/main/java/com/example/order/service/OrderQueryService.java`
- `order-service/src/main/java/com/example/order/dto/OrderQueryReq.java`
- 已有的导出怎么写的，照抄这个形状：`report-service/.../ReportExportController.java`
