# คู่มือการ Build RideScreen iOS เป็นไฟล์ IPA ผ่าน GitHub Actions (วิธีที่ 2)

คู่มือนี้สำหรับผู้ใช้ Windows ที่ไม่มีเครื่อง Mac โดยจะใช้พลังของ **GitHub Actions (macOS Cloud Server)** ในการคอมไพล์โปรเจกต์ Flutter + Swift ให้กลายเป็นไฟล์ติดตั้ง **`.ipa`** สำหรับ iPhone อัตโนมัติ

---

## ขั้นตอนที่ 1: สร้าง Repository บน GitHub (ใช้เวลา 30 วินาที)
1. เปิดเว็บเบราว์เซอร์ไปที่ [github.com/new](https://github.com/new) (เข้าสู่ระบบ GitHub ของคุณ)
2. ตั้งชื่อ **Repository name** เช่น `zontes-screen-ios`
3. เลือกระดับความปลอดภัยเป็น **Public** หรือ **Private** ก็ได้
4. **ไม่ต้องติ๊กถูก** ช่อง "Add a README file"
5. กดปุ่มสีเขียว **"Create repository"**
6. คัดลอก URL ของ Repository (เช่น `https://github.com/<ชื่อของคุณ>/zontes-screen-ios.git`)

---

## ขั้นตอนที่ 2: Push โค้ดขึ้น GitHub (คลิกเดียวผ่านสคริปต์)
1. ดับเบิ้ลคลิกไฟล์ **`push_to_github.bat`** ที่อยู่ในโฟลเดอร์นี้
2. วาง URL ที่คัดลอกมาลงในหน้าต่างคอนโซล แล้วกด **Enter**
3. ระบบจะทำการ Push โค้ดทั้งหมดขึ้น GitHub ให้ทันที

---

## ขั้นตอนที่ 3: รับไฟล์ .ipa จาก GitHub Actions
1. กลับไปที่หน้าเว็บ Repository ของคุณบน GitHub
2. คลิกที่แท็บ **"Actions"** ด้านบน
3. คุณจะเห็น Workflow ชื่อ **`Build iOS (Xcode & IPA)`** กำลังทำงาน (ขึ้นไฟสีเหลืองหมุนๆ)
4. รอระบบบิลด์ประมาณ 3–5 นาที เมื่อเสร็จแล้วจะเปลี่ยนเป็นเครื่องหมายถูกสีเขียว
5. คลิกเข้าไปที่ผลการบิลด์ เลื่อนลงมาล่างสุดที่หัวข้อ **Artifacts**
6. คลิกดาวน์โหลดไฟล์ **`RideScreen-iOS-IPA`** (ข้างในจะมีไฟล์ `RideScreen-iOS.ipa`)

---

## ขั้นตอนที่ 4: ติดตั้งลง iPhone บนคอมพิวเตอร์ Windows
เนื่องจากเป็นไฟล์ `.ipa` คุณสามารถติดตั้งลง iPhone ได้ง่ายๆ บน Windows ผ่านโปรแกรม Sideload ดังนี้:

### ใช้โปรแกรม Sideloadly (แนะนำ สะดวกที่สุด):
1. ดาวน์โหลดโปรแกรม [Sideloadly](https://sideloadly.io/) ติดตั้งบน Windows
2. เสียบสาย iPhone เข้ากับคอมพิวเตอร์ Windows
3. ลากไฟล์ `RideScreen-iOS.ipa` มาวางใส่ใน Sideloadly
4. กรอก Apple ID ของคุณ แล้วกด **Start**
5. รอ 1 นาที แอป **RideScreen** จะไปปรากฏบนหน้าจอ iPhone พร้อมใช้งานทันทีครับ!
