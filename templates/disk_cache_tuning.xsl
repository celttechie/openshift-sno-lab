<?xml version="1.0" encoding="UTF-8"?>
<!--
  XSLT Transformation for SNO Domain Disk Latency Optimization
  Ensures the target root disk has cache='none' and io='threads' (or native)
  to satisfy OpenShift etcd fsync latency requirements (<10ms p99).
-->
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
  <!-- Identity transform: copies everything as-is unless explicitly matched -->
  <xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
    </xsl:copy>
  </xsl:template>

  <!-- Inject optimized caching and asynchronous I/O driver options onto persistent disk -->
  <xsl:template match="disk[@device='disk']/driver">
    <xsl:copy>
      <xsl:apply-templates select="@*"/>
      <xsl:attribute name="cache">none</xsl:attribute>
      <xsl:attribute name="io">threads</xsl:attribute>
    </xsl:copy>
  </xsl:template>

  <!-- Enforce modern virtio-scsi controller for RHEL 9 / CoreOS compatibility -->
  <xsl:template match="controller[@type='scsi']">
    <xsl:copy>
      <xsl:apply-templates select="@*"/>
      <xsl:attribute name="model">virtio-scsi</xsl:attribute>
      <xsl:apply-templates select="node()"/>
    </xsl:copy>
  </xsl:template>
</xsl:stylesheet>
