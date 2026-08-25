# 护照 OCR 价格核对（2026-08-23）

以下价格来自官方页面，实际结算可能受区域、税费、汇率、账号协议和活动影响。

## Mindee

来源：https://www.mindee.com/pricing
来源：https://docs.mindee.com/account-management/plans

官方价格页显示 Starter 约 $44/月（按年计费页面显示 $529/年），Pro 约 $116/月（按年计费页面显示 $1,393/年）；官方文档页面显示 Starter €44/月、Pro €116/月、每档 6,000 credits，年付约省 10%。免费试用为 14 天或 200 pages/credits，以官方账户页面为准。Mindee 按物理页计费，多页 PDF 按页数消耗 credits；官方说明只有成功处理的文件计入 credits。额外 credits 从约 $0.05/credit 起，具体按账户配置和模型计算。

## Azure AI Document Intelligence

来源：https://azure.microsoft.com/en-us/pricing/details/document-intelligence/
来源：https://learn.microsoft.com/en-us/azure/ai-services/document-intelligence/prebuilt/id-document?view=doc-intel-4.0.0

官方价格页显示 Pay-as-you-go 的 Prebuilt models（包括 ID）约 $10/1,000 pages；批量 Prebuilt 也是 $10/1,000 pages。官方 FAQ/价格页显示 F0 免费层可用于测试，价格页当前显示 0–500 pages free/month；实际额度需以 Azure 账户和区域为准。S0 还提供大型承诺档，例如 20,000 pages $190/月、100,000 pages $900/月、500,000 pages $4,000/月。Azure ID 模型官方文档说明支持 worldwide passports，并返回姓名、生日、有效期、证件号、国籍、性别和 MRZ。

## 腾讯云

来源：https://cloud.tencent.com/document/product/866/17619
来源：https://cloud.tencent.com/document/product/866/37657

官方中国站价格页列出多国多地区护照识别归入通用证照识别：预付资源包 1,000 次 120 元、10,000 次 800 元、100,000 次 5,000 元、1,000,000 次 30,000 元；后付费按月阶梯为月调用量小于 10,000 次 0.15 元/次，10,000–100,000 次 0.10 元/次，100,000–1,000,000 次 0.06 元/次。开通部分 OCR 服务可得共享 1,000 次/月免费额度。若使用境外 Region（例如新加坡），官方说明按国际站标准后付费，不能抵扣中国大陆站资源包。官方护照接口明确列出马来西亚、新加坡等国家，返回护照号、姓名、生日、性别、有效期、发行国、国籍、MRZ 和人像。

## 阿里云

来源：https://help.aliyun.com/zh/ocr/product-overview/resource-plans
来源：https://help.aliyun.com/zh/ocr/developer-reference/api-ocr-api-2021-07-07-recognizepassport

官方资源包页面列出国际护照识别按共享点数计费：500 次/点 45 元、1,000 83.3 元、10,000 550 元、100,000 2,805 元；国际护照每次成功调用抵扣 10 点。官方接口文档说明国际护照识别单图不超过 10MB，暂不支持 PDF；因此多页 PDF 需先转图片。该接口支持多个国家护照和 MRZ 字段。

## AWS

来源：https://docs.aws.amazon.com/textract/latest/dg/how-it-works-identity.html

官方 AnalyzeID 文档当前说明主要处理美国政府签发的护照和其他身份文件，不适合本项目需要的马来西亚及多国护照主流程。

## 初步成本判断

按 1 页 = 1 份护照资料页估算，Azure S0 约为 $10/1,000 页，腾讯云中国站约为人民币 120 元/1,000 次预付或 0.15 元/次低量后付费，阿里云约为人民币 83.3 元/1,000 点（国际护照每次 10 点，需以当前资源包购买页为准）。Mindee 不是纯按次低价产品，而是订阅 6,000 credits 起，适合重视专用护照模型、快速接入和 PDF/多页能力的场景。以上不含 Supabase Storage、Worker 主机、网络、税费和真实身份验真服务费用。
