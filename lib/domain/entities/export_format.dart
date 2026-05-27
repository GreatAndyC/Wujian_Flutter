enum ExportFormat {
  pdf('PDF'),
  excel('Excel'),
  markdown('Markdown');

  const ExportFormat(this.label);

  final String label;
}
