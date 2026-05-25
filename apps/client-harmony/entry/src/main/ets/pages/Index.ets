@Entry
@Component
struct Index {
  @State coreUrl: string = 'http://127.0.0.1:9330';

  build() {
    Column() {
      Row() {
        Text('IntMusic')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
        Blank()
        Button('Scan')
      }
      .width('100%')
      .padding(16)

      TextInput({ text: this.coreUrl, placeholder: 'Core URL' })
        .onChange((value: string) => {
          this.coreUrl = value;
        })
        .margin({ left: 16, right: 16, bottom: 12 })

      List() {
        ListItem() { Text('Albums') }
        ListItem() { Text('Artists') }
        ListItem() { Text('Tracks') }
        ListItem() { Text('Search') }
        ListItem() { Text('Outputs') }
        ListItem() { Text('Settings') }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#101418')
  }
}
