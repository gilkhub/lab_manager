# encoding: UTF-8
# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# Note that this schema.rb definition is the authoritative source for your
# database schema. If you need to create the application database on another
# system, you should be using db:schema:load, not running all the migrations
# from scratch. The latter is a flawed and unsustainable approach (the more migrations
# you'll amass, the slower it'll run and the greater likelihood for issues).
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema.define(version: 20151118130706) do

  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "actions", force: :cascade do |t|
    t.integer  "compute_id"
    t.string   "command",      default: "",       null: false
    t.string   "state",        default: "queued", null: false
    t.text     "reason"
    t.text     "payload"
    t.string   "job_id"
    t.text     "action_data"
    t.string   "file_storage"
    t.datetime "pending_at"
    t.datetime "finished_at"
    t.datetime "created_at",                      null: false
    t.datetime "updated_at",                      null: false
  end

  create_table "computes", force: :cascade do |t|
    t.string   "name"
    t.string   "state"
    t.string   "image"
    t.string   "provider_name"
    t.text     "user_data"
    t.text     "ips"
    t.text     "create_vm_options"
    t.text     "provider_data"
    t.datetime "created_at",        null: false
    t.datetime "updated_at",        null: false
  end

  create_table "file_storages", force: :cascade do |t|
    t.integer "action_id"
    t.string  "file"
  end

  create_table "snapshots", force: :cascade do |t|
    t.string   "name"
    t.integer  "compute_id"
    t.string   "provider_ref"
    t.text     "provider_data"
    t.datetime "created_at",    null: false
    t.datetime "updated_at",    null: false
  end

  add_index "snapshots", ["compute_id"], name: "index_snapshots_on_compute_id", using: :btree

  add_foreign_key "snapshots", "computes"
end
