<script setup>
import { metricItems } from './report-format'
defineProps({ report: { type: Object, required: true } })
</script>

<template>
  <div class="detail-metrics">
    <div v-for="[label, value] in metricItems(report)" :key="label"><span>{{ label }}</span><strong>{{ value }}</strong></div>
  </div>
</template>
