# 仓库管家 — 手机 PWA 仓库库存管理

## 功能

- 邮箱密码员工账号，员工 / 主管 / 老板三级权限
- 商品条码（Code128）、手机摄像头扫描、手动选择
- kg / 斤 / 包 / 箱 / 件 / 个基础单位与商品专属换算
- 单仓库原子出入库、库存不足阻止出库、期初库存登记
- 流水查询、整单冲销（主管/老板）、审计日志
- 盘点申请、主管审批、盘点期间库存变动防护
- Excel 初始库存导入与流水导出、库存预警
- PWA 安装到手机桌面

## 1. Supabase 初始化

1. 新建 Supabase 项目。
2. 在 SQL Editor 运行 `supabase/schema.sql` 的全部内容。请使用新项目，避免旧项目同名表或策略冲突。
3. Authentication → Providers → Email 开启邮箱登录。建议关闭公开注册；员工由老板在 Authentication → Users → Add user 中创建（勾选邮箱已确认）。
4. 创建第一个老板账号后，在 SQL Editor 执行（替换邮箱）：

```sql
update public.profiles set role='admin', display_name='老板' where id=(select id from auth.users where email='boss@example.com');
```

5. 创建其他员工后，老板在应用的「员工权限」页设置角色；首次显示名可在 SQL Editor 修改：

```sql
update public.profiles set display_name='张三' where id=(select id from auth.users where email='staff@example.com');
```

**不要把 service_role / secret key 放进前端。** 只使用 Supabase 的 publishable/anon key。建议在 Supabase 开启数据库自动备份（以所选套餐功能为准），为员工设置强密码。

## 2. 本地启动

安装 Node.js 20+：

```bash
npm install
cp .env.example .env
# 编辑 .env，填入项目 Project URL 和 publishable/anon key
npm run dev
```

打开本地显示的地址。摄像头通常要求 HTTPS 或 localhost；手机测试请部署 HTTPS 域名。

## 3. 部署 Vercel（或 Netlify）

- 把整个项目上传到自己的 GitHub 仓库。
- 在 Vercel 中 Import Git Repository，Framework 选择 Vite，Build Command 为 `npm run build`，Output Directory 为 `dist`。
- 配置环境变量 `VITE_SUPABASE_URL`、`VITE_SUPABASE_ANON_KEY`，重新部署。
- 用手机打开部署后 HTTPS 链接，浏览器菜单选择“添加到主屏幕”。
- 登录员工账号，先添加商品，再入库/导入期初数据。

## 4. Excel 导入说明

老板/主管可见导入入口，但 **期初库存写入仅老板可执行**，因此建议由老板完成。先下载应用内模板：

| 商品编码 | 商品名称 | 基础单位 | 期初数量 | 预警数量 | 换算单位 |
|---|---|---|---:|---:|---|
| 10001 | 牛腩 | kg | 20 | 5 | 箱:20,斤:0.5 |
| 10002 | 包装盒 | 个 | 500 | 100 | 箱:500 |

导入按行执行，**不是整表事务**：出现部分失败时不要盲目重复导入；请根据结果和流水核对。对同商品期初数量大于0的记录，系统禁止重复录入。若原始数量为0，不会产生期初流水，后续仍可补录一次。商品编码带前导零时，请把 Excel 该列设为文本格式。

## 5. 审计与业务规则

- 所有客户端业务写入通过 SECURITY DEFINER RPC 处理，普通客户端只有查询权限。
- `stock_transactions` 不提供客户端 UPDATE/DELETE；错误流水只能由主管/老板整单冲销，原单与冲销单均保留。
- `audit_logs` 由数据库触发器写入，普通账号不能编辑。**项目数据库拥有者仍有数据库级修改权限**，因此“不可篡改”是对应用账号而言，不代表具备独立合规存证级别的防篡改能力。
- 盘点以基础单位填写，审核时验证当前库存与盘点快照一致，若不一致必须重新盘点。
- 所有数量保留最多三位小数；换算后的库存数量会四舍五入至三位小数。
- 多人并发变更使用行级锁，防止库存丢失更新。
- 历史流水、日志在前端各显示最近300/200条；大规模数据应增加服务端分页与完整时间范围导出。

## 6. 上线前测试

1. 新建商品「牛腩」，基础单位 kg，换算箱:20、斤:0.5。
2. 录入期初20kg，入库1箱，库存应为40kg。
3. 出库5斤，库存应为37.5kg。
4. 尝试出库100kg，系统应拒绝。
5. 用员工账号提交盘点37kg，用主管账号审核，库存变为37kg。
6. 再做一笔入库后审核旧盘点，应因快照过期而拒绝。
7. 冲销一笔入库，原单保留并生成反向流水；库存不足时冲销也会被拒绝。
8. 员工账号不应看到审计日志或权限管理，也不应能调用审核 RPC。
9. 手机 HTTPS 页面测试摄像头识别 Code128；添加主屏幕后重新打开验证登录。

## 已知限制 / 后续增强

- 当前提供的是可部署 MVP，不是经过生产环境安全审计的商业成品。
- 仅单仓库；未实现离线写入、批次/保质期、供应商、库存金额、批量一单多商品、照片凭证、审批冲销申请。
- 管理员新增员工账号需要 Supabase 控制台；若希望在手机端直接创建员工，可后续加一条受保护的 Edge Function。
- 当前 PWA 图标使用 SVG；部分 iOS 版本可能需要补充 PNG 图标。
- 每笔出入库均单独生成流水；导入失败处理及正式上线前需要在自己的 Supabase 环境验证。
