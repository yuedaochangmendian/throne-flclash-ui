package io.nekohasekai.sagernet.database

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import androidx.room.Update

@Dao
interface RouteDao {

    @Query("SELECT * FROM route_profiles ORDER BY id")
    fun allProfiles(): List<RouteProfileEntity>

    @Query("SELECT id FROM route_profiles ORDER BY id")
    fun allIds(): List<Long>

    @Query("SELECT * FROM route_profiles WHERE id = :id")
    fun getProfile(id: Long): RouteProfileEntity?

    @Query("SELECT COUNT(*) FROM route_profiles")
    fun count(): Long

    /** The profile's dns_json while custom_dns is on; null when it is off or the profile does not exist. */
    @Query("SELECT dns_json FROM route_profiles WHERE id = :id AND custom_dns != 0")
    fun customDnsJson(id: Long): String?

    /** Whether [id] names a profile Android can build with (not raw). */
    @Query("SELECT EXISTS(SELECT 1 FROM route_profiles WHERE id = :id AND is_raw = 0)")
    fun isUsable(id: Long): Boolean

    /** RoutesRepo::OwnedBy: the profiles the subscription group [gid] keeps updated. */
    @Query("SELECT id FROM route_profiles WHERE source_gid = :gid ORDER BY id")
    fun ownedBy(gid: Long): List<Long>

    /** The groups owning any of [ids]. */
    @Query("SELECT DISTINCT source_gid FROM route_profiles WHERE id IN (:ids) AND source_gid > 0")
    fun sourceGroups(ids: List<Long>): List<Long>

    @Query("SELECT * FROM route_rules ORDER BY route_profile_id, rule_order")
    fun allRules(): List<RouteRuleEntity>

    @Query("SELECT * FROM route_rules WHERE route_profile_id = :profileId ORDER BY rule_order")
    fun rulesOf(profileId: Long): List<RouteRuleEntity>

    @Insert
    fun insertProfile(profile: RouteProfileEntity): Long

    @Update
    fun updateProfile(profile: RouteProfileEntity): Int

    @Query("DELETE FROM route_profiles WHERE id = :id")
    fun deleteProfile(id: Long): Int

    @Query("DELETE FROM route_rules WHERE route_profile_id = :profileId")
    fun deleteRules(profileId: Long)

    @Insert
    fun insertRules(rules: List<RouteRuleEntity>)

    /** Every server profile a rule or a default outbound names. */
    @Query(
        "SELECT outbound_id FROM route_rules WHERE outbound_id > 0 " +
            "UNION SELECT default_outbound_id FROM route_profiles WHERE default_outbound_id > 0"
    )
    fun referencedOutboundIds(): List<Long>

    @Query("UPDATE route_rules SET outbound_id = :newId WHERE outbound_id = :oldId")
    fun replaceRuleOutbound(oldId: Long, newId: Long): Int

    @Query("UPDATE route_profiles SET default_outbound_id = :newId WHERE default_outbound_id = :oldId")
    fun replaceDefaultOutbound(oldId: Long, newId: Long): Int

    /** Every profile; their rules go by the foreign key cascade. */
    @Query("DELETE FROM route_profiles")
    fun reset()

    // ------------------------------------------------------------------ global added-rules pool

    @Query("SELECT * FROM global_route_rules ORDER BY rule_order")
    fun globalRules(): List<GlobalRouteRuleEntity>

    @Insert
    fun insertGlobalRules(rules: List<GlobalRouteRuleEntity>)

    @Query("DELETE FROM global_route_rules")
    fun deleteGlobalRules()

    @Query("DELETE FROM global_route_rules WHERE rule_id = :ruleId")
    fun deleteGlobalRule(ruleId: Long)

    /** One profile's disabled ids, read raw for the bridge and the build. */
    @Query("SELECT disabled_global_rule_json FROM route_profiles WHERE id = :profileId")
    fun disabledGlobalRuleJson(profileId: Long): String?

    @Query("UPDATE route_profiles SET disabled_global_rule_json = :json WHERE id = :profileId")
    fun updateDisabledGlobalRuleJson(profileId: Long, json: String): Int
}
